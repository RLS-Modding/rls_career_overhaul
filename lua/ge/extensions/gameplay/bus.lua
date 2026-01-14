local M = {}
M.dependencies = {'gameplay_sites_sitesManager', 'freeroam_facilities'}

local core_groundMarkers = require('core/groundMarkers')
local core_vehicles = require('core/vehicles')

local DEBUG = false

local currentStopIndex = nil
local stopTriggers = {}
local dwellTimer = nil
local dwellDuration = 10
local consecutiveStops = 0
local currentRouteActive = false
local accumulatedReward = 0
local passengersOnboard = 0
local activeBusID = nil
local routeInitialized = false
local totalStopsCompleted = 0
local routeCooldown = 0
local currentVehiclePartsTree = nil
local stopMonitorActive = false
local stopSettleTimer = 0
local stopSettleDelay = 2.5
local currentTriggerName = nil
local roughRide = 0
local lastVelocity = nil
local tipTotal = 0
local trueBoarding = 0
local trueDeboarding = 0
local boardingCoroutine = nil
local currentFinalStopName = nil
local stopIndexWhereBoardingStarted = nil
local pendingRouteInit = false
local isCalculatingRoute = false
local routeCalcTimer = 0
local currentRouteName = nil
local stopDisplayNames = {}
local routeItems = {}
local stopMarkerObjects = {}
local stopPerimeterTrigger = nil
local currentLoanerCut = 0

local isBus
local initRoute

-- Map known part-name patterns to explicit seating capacities for special-case vehicle parts.
-- @param partName The parts-tree node name to test (string).
-- @return The seating capacity for matching special-case part names, or `nil` if no special case applies.
local function specificCapacityCases(partName)
    if partName:find("capsule") and partName:find("seats") then
        if partName:find("sd12m") then
            return 25
        elseif partName:find("sd18m") then
            return 41
        elseif partName:find("sd105") then
            return 21
        elseif partName:find("sd_seats") then
            return 33
        elseif partName:find("dd105") then
            return 29
        elseif partName:find("sd195") then
            return 43
        elseif partName:find("lhd_artic_seats_upper") then
            return 77
        elseif partName:find("lhd_artic_seats") then
            return 30
        elseif partName:find("lh_seats_upper") then
            return 53
        elseif partName:find("lh_seats") then
            return 17
        elseif partName:find("lhd_seats_upper") then
            return 53
        elseif partName:find("lhd_seats") then
            return 17
        elseif partName:find("rhd_artic_seats_upper") then
            return 77
        elseif partName:find("rhd_artic_seats") then
            return 30
        end
    end

    if partName:find("schoolbus_seats_R_c") then
        return 10
    end
    if partName:find("schoolbus_seats_L_c") then
        return 10
    end
    if partName:find("limo_seat") then
        return 8
    end

    return nil
end

-- Recursively traverses a vehicle parts tree to accumulate seating capacity based on seat-related parts and special-case part names.
-- @param partData Table representing a list/tree of part nodes; each node may contain `chosenPartName` and `children`.
-- @param seatingCapacity Number initial seating capacity accumulator (use 0 to start counting from scratch).
-- @return Number total seating capacity after processing `partData`.
local function cyclePartsTree(partData, seatingCapacity)
    for _, part in pairs(partData) do
        local partName = part.chosenPartName or ""

        if partName:find("seat") and not partName:find("cargo") and not partName:find("captains") then
            local seatSize = 1
            if partName:find("seats") then
                seatSize = 3
            elseif partName:find("ext") then
                seatSize = 2
            elseif partName:find("skin") then
                seatSize = 0
            end

            seatSize = specificCapacityCases(partName) or seatSize
            seatingCapacity = seatingCapacity + seatSize
        end

        if part.children then
            seatingCapacity = cyclePartsTree(part.children, seatingCapacity)
        end

        if partName == "pickup" then
            seatingCapacity = math.max(seatingCapacity, 7)
        end
    end

    return seatingCapacity
end

-- Determine seating capacity from the current vehicle parts tree.
-- If the parts tree is unavailable or malformed, a fallback capacity of 20 is used.
-- The result is clamped to be at least 1.
-- @return The computed seating capacity (number), at least 1; uses 20 when parts data is missing or an error occurs.
local function calculateSeatingCapacity()
    local fallbackCapacity = 20
    if not currentVehiclePartsTree then
        return fallbackCapacity
    end
    if type(currentVehiclePartsTree) ~= "table" then
        print("[bus] Warning: currentVehiclePartsTree is not a table, using fallback capacity")
        return fallbackCapacity
    end
    local success, result = pcall(cyclePartsTree, {currentVehiclePartsTree}, 0)
    if not success then
        print(string.format("[bus] Warning: Error calculating seating capacity: %s", tostring(result)))
        return fallbackCapacity
    end
    return math.max(1, result or fallbackCapacity)
end

-- Requests the current player's vehicle parts tree from the game engine and clears any cached copy.
-- After calling, if a player vehicle exists, an asynchronous request is queued; the retrieved parts tree is delivered back to the extension via gameplay_bus.returnPartsTree.
local function retrievePartsTree()
    currentVehiclePartsTree = nil
    local vehicle = be:getPlayerVehicle(0)
    if vehicle then
        vehicle:queueLuaCommand([[
      local partsTree = v.config.partsTree
      obj:queueGameEngineLua('gameplay_bus.returnPartsTree(' .. serialize(partsTree) .. ')')
    ]])
    end
end

-- Processes a vehicle parts tree to determine and store the vehicle's passenger seating capacity.
-- Updates module state with the detected parts tree and computed capacity, applies known overrides for specific vehicle types, logs and displays the detected capacity, and triggers deferred route initialization if pending.
-- @param partsTree Table representing the vehicle parts tree (may be nested); used to compute seating capacity and to detect model-specific capacity overrides.
local function returnPartsTree(partsTree)
    currentVehiclePartsTree = partsTree
    local seats = calculateSeatingCapacity()
    M.vehicleCapacity = math.max(1, seats)

    local capOverrides = {
        ["schoolbus_interior_b"] = 24,
        ["schoolbus_interior_c"] = 40,
        ["prisonbus"] = 20,
        ["citybus_seats"] = 44,
        ["citybus"] = 44,
        ["dm_vanbus"] = 24,
        ["vanbus"] = 24,
        ["van_bus"] = 24,
        ["vanbusframe"] = 24
    }

    local capOverride = nil
    local function checkPartTreeForKeywords(tree)
        if capOverride then return end
        for k, v in pairs(tree) do
            if type(k) == "string" then
                local name = string.lower(k)
                for pattern, capacity in pairs(capOverrides) do
                    if name:find(pattern) then
                        capOverride = capacity
                        print(string.format("[bus] %s detected via partsTree → capacity %d", pattern, capacity))
                        return
                    end
                end
            end
            if type(v) == "table" then
                checkPartTreeForKeywords(v)
                if capOverride then return end
            end
        end
    end

    checkPartTreeForKeywords(partsTree)

    if capOverride then
        M.vehicleCapacity = capOverride
    elseif M.vehicleCapacity <= 12 then
        M.vehicleCapacity = 12
        print("[bus] Generic or van-based transport detected → fallback capacity 12")
    end

    print(string.format("[bus] Vehicle seating capacity detected: %d seats", M.vehicleCapacity))
    ui_message(string.format("Vehicle seating capacity detected: %d passengers.", M.vehicleCapacity), 5, "info", "info")

    if pendingRouteInit then
        pendingRouteInit = false
        initRoute()
    end
end

-- Create and register a corner marker TSStatic used for stop-perimeter visualization.
-- The marker is registered under the given name and added to scenetree.MissionGroup if present.
-- @param markerName string The name used to register the marker in the scene.
-- @return table The created TSStatic marker object.
local function createCornerMarker(markerName)
    local marker = createObject('TSStatic')
    marker:setField('shapeName', 0, "art/shapes/interface/position_marker.dae")
    marker:setPosition(vec3(0, 0, 0))
    marker.scale = vec3(1, 1, 1)
    marker:setField('rotation', 0, '1 0 0 0')
    marker.useInstanceRenderData = true
    marker:setField('instanceColor', 0, '1 1 1 1')
    marker:setField('collisionType', 0, "Collision Mesh")
    marker:setField('decalType', 0, "Collision Mesh")
    marker:setField('playAmbient', 0, "1")
    marker:setField('allowPlayerStep', 0, "1")
    marker:setField('canSave', 0, "0")
    marker:setField('canSaveDynamicFields', 0, "1")
    marker:setField('renderNormals', 0, "0")
    marker:setField('meshCulling', 0, "0")
    marker:setField('originSort', 0, "0")
    marker:setField('forceDetail', 0, "-1")
    marker.canSave = false
    marker:registerObject(markerName)
    if scenetree and scenetree.MissionGroup then
        scenetree.MissionGroup:addObject(marker)
    end
    return marker
end

-- Safely deletes a scenetree object and any matching instance found by name.
-- If an object with the same name exists in scenetree, that instance is removed first.
-- Calls editor.onRemoveSceneTreeObjects with the object's id before deletion when the editor hook is available.
-- Errors during deletion are suppressed; if `objName` is provided, a failure will be printed with that name.
-- @param obj The scenetree object to delete (may be nil or invalid).
-- @param objName Optional human-readable name used in error logging.
local function safeDelete(obj, objName)
    if not obj then
        return
    end
    local success, err = pcall(function()
        local name = obj:getName()
        local found = name and scenetree.findObject(name) or nil
        local sameObject = found and (found == obj or found:getId() == obj:getId())

        if sameObject then
            if editor and editor.onRemoveSceneTreeObjects then
                editor.onRemoveSceneTreeObjects({obj:getId()})
            end
            obj:delete()
        else
            if found then
                if editor and editor.onRemoveSceneTreeObjects then
                    editor.onRemoveSceneTreeObjects({found:getId()})
                end
                found:delete()
            end
            if obj:isValid() then
                if editor and editor.onRemoveSceneTreeObjects then
                    editor.onRemoveSceneTreeObjects({obj:getId()})
                end
                obj:delete()
            end
        end
    end)
    if not success and objName then
        print(string.format("[bus] Error deleting %s: %s", objName, tostring(err)))
    end
end

-- Removes all stop marker objects and the active stop perimeter trigger.
-- After this call the internal marker list is cleared and the stored perimeter trigger is set to nil.
local function clearStopMarkers()
    for _, obj in ipairs(stopMarkerObjects) do
        safeDelete(obj, "marker")
    end
    table.clear(stopMarkerObjects)
    safeDelete(stopPerimeterTrigger, "perimeter trigger")
    stopPerimeterTrigger = nil
end

-- Creates visual corner markers and a box-shaped perimeter trigger for a bus stop trigger.
-- Clears any existing stop markers, computes corner positions from the trigger's transform (or uses defaults),
-- raycasts to place markers on the ground, spawns corner TSStatic markers (stored in stopMarkerObjects)
-- and a BeamNGTrigger box (stored in stopPerimeterTrigger). Marker and perimeter names include a unique id.
-- @param trigger The scenetree trigger object representing the bus stop; if nil the function does nothing.
local function createStopPerimeter(trigger)
    if not trigger then
        return
    end

    clearStopMarkers()

    local triggerPos = trigger:getPosition()
    local triggerRot = trigger:getRotation()
    local triggerScale = trigger:getScale()

    local stopLength = triggerScale and triggerScale.x or 15
    local stopWidth = triggerScale and triggerScale.y or 8
    local stopHeight = triggerScale and triggerScale.z or 5

    local rot = quat(triggerRot)
    local vecX = rot * vec3(1, 0, 0)
    local vecY = rot * vec3(0, 1, 0)
    local vecZ = rot * vec3(0, 0, 1)

    local halfLength = stopLength * 0.5
    local halfWidth = stopWidth * 0.5

    local corners = {{
        pos = triggerPos - vecX * halfLength + vecY * halfWidth,
        name = "TL"
    },
    {
        pos = triggerPos + vecX * halfLength + vecY * halfWidth,
        name = "TR"
    },
    {
        pos = triggerPos + vecX * halfLength - vecY * halfWidth,
        name = "BR"
    },
    {
        pos = triggerPos - vecX * halfLength - vecY * halfWidth,
        name = "BL"
    }
    }

    local qOff = quatFromEuler(0, 0, math.pi / 2) * quatFromEuler(0, math.pi / 2, math.pi / 2)
    local rotations = {quatFromEuler(0, 0, math.rad(90)),
    quatFromEuler(0, 0, math.rad(180)),
    quatFromEuler(0, 0, math.rad(270)),
    quatFromEuler(0, 0, 0)
    }

    local uniqueId = os.time() .. "_" .. math.random(1000, 9999)
    for i, corner in ipairs(corners) do
        local markerName = string.format("busStopMarker_%s_%d_%s", trigger:getName() or "unknown", i, uniqueId)

        local hit = Engine.castRay(corner.pos + vecZ * 2, corner.pos - vecZ * 10, true, false)
        local groundPos = hit and vec3(hit.pt) or (corner.pos + vecZ * 0.05)
        groundPos = groundPos + vecZ * 0.05

        local finalRot = rotations[i] * qOff * quatFromDir(vec3(0, 0, 1), vecY)

        local marker = createCornerMarker(markerName)
        marker:setPosRot(groundPos.x, groundPos.y, groundPos.z, finalRot.x, finalRot.y, finalRot.z, finalRot.w)
        marker:setField('instanceColor', 0, "0.6 0.9 0.23 1")
        table.insert(stopMarkerObjects, marker)
    end

    local perimeterName = string.format("busStopPerimeter_%s_%s", trigger:getName() or "unknown", uniqueId)
    local perimeterTrigger = createObject('BeamNGTrigger')
    perimeterTrigger.loadMode = 1
    perimeterTrigger:setField("triggerType", 0, "Box")
    perimeterTrigger:setPosition(triggerPos)
    perimeterTrigger:setScale(vec3(stopLength, stopWidth, stopHeight))
    local rotTorque = rot:toTorqueQuat()
    perimeterTrigger:setField('rotation', 0,
        rotTorque.x .. ' ' .. rotTorque.y .. ' ' .. rotTorque.z .. ' ' .. rotTorque.w)
    perimeterTrigger:registerObject(perimeterName)
    stopPerimeterTrigger = perimeterTrigger

    print(string.format("[bus] Created perimeter markers for stop: %s (scale: %.1f x %.1f x %.1f)",
        trigger:getName() or "unknown", stopLength, stopWidth, stopHeight))
end

-- Display perimeter markers for a bus stop.
-- If `stopIndex` is omitted, uses the module's `currentStopIndex`.
-- @param stopIndex? Optional index of the stop whose markers should be shown.
local function showCurrentStopMarkers(stopIndex)
    local targetStopIndex = stopIndex or currentStopIndex
    if not targetStopIndex or not stopTriggers or not stopTriggers[targetStopIndex] then
        print("[bus] showCurrentStopMarkers: Invalid stop index or triggers")
        return
    end

    local currentTrigger = stopTriggers[targetStopIndex]
    local triggerName = currentTrigger:getName() or "unknown"
    print(string.format("[bus] Showing markers for stop %d: %s", targetStopIndex, triggerName))
    createStopPerimeter(currentTrigger)
end

local function hideStopMarkers()
    clearStopMarkers()
end

isBus = function(vehicle)
    if not vehicle then return false end
    local plate = core_vehicles.getVehicleLicenseText(vehicle)
    return plate and plate:upper() == "BUS"
end

local function calculateLoanerCut(vehId)
    if not vehId then
        return 0
    end
    
    if not career_modules_loanerVehicles or not career_modules_loanerVehicles.getLoaningOrgsOfVehicle then
        return 0
    end
    
    local loaningOrgs = career_modules_loanerVehicles.getLoaningOrgsOfVehicle(vehId)
    if not loaningOrgs or not next(loaningOrgs) then
        return 0
    end
    
    local totalCut = 0
    for organizationId, _ in pairs(loaningOrgs) do
        local organization = freeroam_organizations.getOrganization(organizationId)
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

local function getNextTrigger()
    if not currentStopIndex then
        return nil
    end
    return stopTriggers[currentStopIndex]
end

local function getItemPosition(item)
    return item.position or (item.trigger and item.trigger:getPosition())
end

local function buildPathToStop(targetStopIndex, startPos, fromStopIndex)
    local pathPoints = {startPos}
    if not routeItems or #routeItems == 0 then
        return pathPoints
    end

    if not stopTriggers or #stopTriggers == 0 then
        return pathPoints
    end

    local currentStopIdx = fromStopIndex or currentStopIndex or 1
    local nextStopIndex = targetStopIndex
    if nextStopIndex > #stopTriggers then
        nextStopIndex = 1
    end

    local currentItemIndex = nil
    if DEBUG then
        print(string.format("[bus] DEBUG: Searching for current stop with stopIndex=%d in routeItems (total items: %d)",
            currentStopIdx, #routeItems))
    end
    for i, item in ipairs(routeItems) do
        if DEBUG then
            local itemName = item.waypointName or (item.trigger and item.trigger:getName()) or "unknown"
            print(string.format("[bus] DEBUG: routeItems[%d]: type=%s, stopIndex=%s, name=%s", i, item.type,
                tostring(item.precedingStopIndex), itemName))
        end
        if item.type == "stop" and item.precedingStopIndex == currentStopIdx then
            currentItemIndex = i
            if DEBUG then
                print(string.format("[bus] DEBUG: Found current stop at routeItems index %d", i))
            end
            break
        end
    end

    if not currentItemIndex then
        for i, item in ipairs(routeItems) do
            if item.type == "stop" and item.precedingStopIndex == nextStopIndex then
                local pos = getItemPosition(item)
                if pos then
                    table.insert(pathPoints, pos)
                end
                return pathPoints
            end
        end
        return pathPoints
    end

    local waypointCount = 0
    if currentItemIndex then
        if DEBUG then
            print(string.format(
                "[bus] DEBUG: Starting search from routeItems index %d, looking for waypoints before stop %d",
                currentItemIndex + 1, nextStopIndex))
        end
        for i = currentItemIndex + 1, #routeItems do
            local item = routeItems[i]
            if DEBUG then
                local itemName = item.waypointName or (item.trigger and item.trigger:getName()) or "unknown"
                print(string.format("[bus] DEBUG: Checking routeItems[%d]: type=%s, stopIndex=%s, name=%s", i,
                    item.type, tostring(item.precedingStopIndex), itemName))
            end
            if item.type == "waypoint" then
                local pos = getItemPosition(item)
                if pos then
                    table.insert(pathPoints, pos)
                    waypointCount = waypointCount + 1
                    if DEBUG then
                        print(string.format("[bus] Added waypoint '%s' to path", item.waypointName or "unknown"))
                    end
                elseif DEBUG then
                    print(string.format("[bus] DEBUG: Waypoint '%s' has no position!", item.waypointName or "unknown"))
                end
            elseif item.type == "stop" then
                if DEBUG then
                    print(string.format("[bus] DEBUG: Found stop with stopIndex=%d, looking for stopIndex=%d",
                        item.precedingStopIndex, nextStopIndex))
                end
                if item.precedingStopIndex == nextStopIndex then
                    local pos = getItemPosition(item)
                    if pos then
                        table.insert(pathPoints, pos)
                    end
                    if DEBUG then
                        print(string.format("[bus] Path built: %d waypoints between stop %d and stop %d", waypointCount,
                            currentStopIdx, nextStopIndex))
                    end
                    break
                elseif item.precedingStopIndex > nextStopIndex then
                    if DEBUG then
                        print(string.format("[bus] DEBUG: Stop index %d > target %d, breaking search",
                            item.precedingStopIndex, nextStopIndex))
                    end
                    break
                end
            end
        end
    elseif DEBUG then
        print(string.format("[bus] DEBUG: Could not find current stop (stopIndex=%d) in routeItems!", currentStopIdx))
    end

    if DEBUG and waypointCount == 0 then
        print(string.format("[bus] No waypoints found between stop %d and stop %d", currentStopIdx, nextStopIndex))
    end

    return pathPoints
end

local function setupRoutePlannerWithWaypoints(pathPoints, targetPos)
    if not pathPoints or #pathPoints == 0 then
        print("[bus] Warning: No path points provided, using direct path to target")
        core_groundMarkers.setPath(targetPos)
        return
    end

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then
        core_groundMarkers.setPath(targetPos)
        return
    end

    local vehPos = vehicle:getPosition()
    local vehDir = vehicle:getDirectionVector()

    local toTarget = (targetPos - vehPos):normalized()
    local dotProduct = vehDir:dot(toTarget)

    local adjustedPathPoints = {}

    local forwardDistance = 25
    local forwardPoint = vehPos + vehDir * forwardDistance
    table.insert(adjustedPathPoints, forwardPoint)

    for i, point in ipairs(pathPoints) do
        if i == 1 and vehPos:distance(point) < 10 then
        else
            local lastPoint = adjustedPathPoints[#adjustedPathPoints]
            if lastPoint:distance(point) > 5 then
                table.insert(adjustedPathPoints, point)
            end
        end
    end

    local lastPoint = adjustedPathPoints[#adjustedPathPoints]
    if lastPoint:distance(targetPos) > 5 then
        table.insert(adjustedPathPoints, targetPos)
    end

    core_groundMarkers.setPath(targetPos)

    if core_groundMarkers.routePlanner then
        core_groundMarkers.routePlanner:setRouteParams(nil, 1e6, nil, nil, nil, nil)
        core_groundMarkers.routePlanner:setupPathMulti(adjustedPathPoints)

        if DEBUG then
            print(string.format("[bus] Direction-aware path set with %d nodes through %d waypoints (target %s vehicle, dot=%.2f)",
                #core_groundMarkers.routePlanner.path, #adjustedPathPoints, dotProduct < 0 and "behind" or "ahead of", dotProduct))
        end
    elseif DEBUG then
        print("[bus] Could not access ground markers routePlanner")
    end
end

local function showNextStopMarker(targetStopIndex)
    local nextStopIndex = targetStopIndex
    if not nextStopIndex then
        nextStopIndex = (currentStopIndex or 1) + 1
        if nextStopIndex > #stopTriggers then
            nextStopIndex = 1
        end
    end

    local trigger = stopTriggers[nextStopIndex]
    if not trigger then
        return
    end

    core_groundMarkers.resetAll()
    local vehicle = be:getPlayerVehicle(0)
    local targetPos = trigger:getPosition()

    if vehicle then
        local fromStopIndex = nextStopIndex - 1
        if fromStopIndex < 1 then
            fromStopIndex = #stopTriggers
        end

        local pathPoints = buildPathToStop(nextStopIndex, vehicle:getPosition(), fromStopIndex)
        if #pathPoints == 1 then
            pathPoints[2] = targetPos
        end

        setupRoutePlannerWithWaypoints(pathPoints, targetPos)
    else
        core_groundMarkers.setPath(targetPos)
    end

    showCurrentStopMarkers(nextStopIndex)
end

local function endRoute(reason, payout)
    currentRouteActive = false
    dwellTimer = nil
    routeInitialized = false
    currentFinalStopName = nil
    currentRouteName = nil
    core_groundMarkers.resetAll()
    hideStopMarkers()

    local msg = "Shift ended."
    if reason then
        msg = msg .. " (" .. reason .. ")"
    end

    local reputationGain = 0

    if payout and payout > 0 then
        local loanerCutAmount = 0
        if currentLoanerCut > 0 then
            loanerCutAmount = math.floor(payout * currentLoanerCut)
            payout = payout - loanerCutAmount
        end

        local basePay = accumulatedReward
        local tipsEarned = tipTotal

        reputationGain = math.floor(payout / 500)

        msg = msg .. string.format("\nStops completed: %d\nBase pay:   $%d\nTips:       $%d",
            totalStopsCompleted, basePay, tipsEarned)
        if loanerCutAmount > 0 then
            msg = msg .. string.format("\nLoaner cut: -$%d", loanerCutAmount)
        end
        msg = msg .. string.format("\n--------------------\nTotal payout: $%d\nReputation gained: +%d",
            payout, reputationGain)
    else
        msg = msg .. "\nNo payout earned."
    end

    ui_message(msg, 8, "info", "info")
    print("[bus] " .. msg:gsub("\n", " "))

    local vehicle = be:getPlayerVehicle(0)
    if vehicle then
        vehicle:queueLuaCommand([[
      if controller and controller.onGameplayEvent then
        controller.onGameplayEvent("bus_onRouteChange", {
          routeId="00", routeID="00", direction="Not in Service", tasklist={}
        })
      end
    ]])
    end

    if payout and payout > 0 and career_career and career_career.isActive() and career_modules_payment and
        career_modules_payment.reward then
        career_modules_payment.reward({
            money = {
                amount = payout
            },
            beamXP = {
                amount = math.floor(payout / 10)
            },
            busWorkReputation = {
                amount = reputationGain
            }
        }, {
            label = string.format("Bus Route Earnings: $%d", payout),
            tags = {"transport", "bus", "gameplay"}
        }, true)
    end

    accumulatedReward, passengersOnboard, totalStopsCompleted, tipTotal = 0, 0, 0, 0
    roughRide, lastVelocity, activeBusID = 0, nil, nil
    currentLoanerCut = 0
end

-- Loads map-specific bus route configurations from disk by locating and parsing a JSON route file for the current level.
-- Searches common map-based filenames and returns the parsed routes table when successful.
-- @return A table mapping route identifiers to route definitions if a valid routes file is found and parsed, `nil` otherwise.
local function loadRoutesFromJSON()
    local currentMap = getCurrentLevelIdentifier()
    print(string.format("[bus] Current map identifier: %s", tostring(currentMap)))
    if not currentMap then
        print("[bus] No current map identifier found")
        return nil
    end

    local possibleFiles = {string.format("/levels/%s/%sBusRoutes.json", currentMap, currentMap:gsub("_", "")),
                           string.format("/levels/%s/busRoutes.json", currentMap),
                           string.format("/levels/%s/%s_bus_routes.json", currentMap, currentMap)}

    local shortPrefix = currentMap:gsub("([^_])[^_]*_?", "%1")
    if DEBUG then
        print(string.format("[bus] DEBUG: currentMap=%s, shortPrefix=%s", currentMap, shortPrefix))
    end
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
        print(string.format("[bus] No route file found for map: %s", currentMap))
        print(string.format("[bus] Searched paths: %s", table.concat(possibleFiles, ", ")))
        return nil
    end

    print(string.format("[bus] Loading route file: %s", routeFile))
    local routeData = jsonReadFile(routeFile)
    if not routeData then
        print(string.format("[bus] Failed to read route file: %s", routeFile))
        return nil
    end
    if not routeData.routes then
        print(string.format("[bus] Route file %s does not contain 'routes' key", routeFile))
        return nil
    end

    print(string.format("[bus] Successfully loaded routes from %s", routeFile))
    return routeData.routes
end

local function collectScenetreeObjects()
    local allTriggers = {}
    local allWaypoints = {}

    -- Processes a scenetree object or its name and registers it as a bus stop trigger or waypoint when its name matches known patterns.
    -- If `obj` is a string, resolves it with `scenetree.findObject`; if resolution fails the function exits silently.
    -- Recognizes bus stop trigger names that end with `_bs_<number>` or `_bs_<number>_b` and stores them in `allTriggers`.
    -- Recognizes waypoint names containing `_wp_` or `_waypoint_` and stores them in `allWaypoints`.
    -- @param obj A scenetree object or the object's name as a string.
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

    if DEBUG then
        local waypointCount = 0
        for _ in pairs(allWaypoints) do
            waypointCount = waypointCount + 1
        end
        print(string.format("[bus] DEBUG: Found %d waypoints in scenetree", waypointCount))
        for name, _ in pairs(allWaypoints) do
            print(string.format("[bus] DEBUG:   - %s", name))
        end
    end

    return allTriggers, allWaypoints
end

-- Selects a random route from a table of routes.
-- @param routes Table mapping route keys to route definitions.
-- @return selectedRoute The route value chosen at random, or `nil` if none exist.
-- @return selectedKey The key corresponding to the chosen route, or `nil` if none exist.
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

-- Constructs route stop and waypoint structures from a selected route configuration.
-- @param selectedRoute Table describing the route; expected to contain a `stops` array where each entry is either a string stop name or a table. Table entries may be `{"wp", waypointName, displayName}` for explicit waypoints or `{stopName, displayName}`.
-- @param allTriggers Map of scenetree trigger objects keyed by stop name; used to resolve stop entries.
-- @param allWaypoints Map of waypoint objects keyed by waypoint name; used to resolve waypoint entries.
-- @return triggers A list of resolved stop trigger objects in the order they appear in the route (waypoints are excluded).
-- @return items An ordered list of route items where each item is either `{ type = "stop", trigger = <obj>, position = <vec>, precedingStopIndex = <int> }` or `{ type = "waypoint", waypointName = <string>, position = <vec>, precedingStopIndex = <int> }`.
-- @return displayNames A map of item name -> display name for stops or waypoints that provided an explicit displayName in the route config.
local function buildRouteFromConfig(selectedRoute, allTriggers, allWaypoints)
    local triggers = {}
    local items = {}
    local displayNames = {}
    local missingStops = {}
    local missingWaypoints = {}
    local stopIndex = 0

    for _, stopData in ipairs(selectedRoute.stops) do
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
                if DEBUG then
                    print(string.format("[bus] Found waypoint '%s' at %s", stopName, tostring(waypointPos)))
                end
            else
                table.insert(missingWaypoints, stopName)
                print(string.format("[bus] Waypoint '%s' not found - skipping (will navigate directly to next stop)", stopName))
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
        print(string.format("[bus] Skipped %d missing waypoints: %s", #missingWaypoints, table.concat(missingWaypoints, ", ")))
    end
    if #missingStops > 0 then
        print(string.format("[bus] Warning: %d stops not found: %s", #missingStops, table.concat(missingStops, ", ")))
    end

    return triggers, items, displayNames
end

-- Configure navigation toward a target stop position; when a vehicle is present, build and apply a waypoint path, otherwise set a direct path to the target position.
-- @param vehicle The player's vehicle object, or nil to indicate no vehicle (causes a direct path to be set).
-- @param targetPos Vector3 world position of the target stop.
-- @param targetStopIndex Index of the target stop within the current route used to construct waypoint path.
local function setupRouteNavigation(vehicle, targetPos, targetStopIndex)
    if not vehicle then
        core_groundMarkers.setPath(targetPos)
        return
    end

    local pathPoints = buildPathToStop(targetStopIndex, vehicle:getPosition())
    if #pathPoints == 1 then
        pathPoints[2] = targetPos
    end

    setupRoutePlannerWithWaypoints(pathPoints, targetPos)
end

-- Update in-vehicle bus controller and UI with the current route and remaining stops.
-- Constructs a `routeData` object containing `direction` and an ordered `tasklist` of stop identifiers/labels starting from the current stop,
-- sends it to the player's vehicle controller via the `bus_setLineInfo` gameplay event when a vehicle is present,
-- and triggers the `BusDisplayUpdate` GUI hook with the same `routeData`.
local function updateBusControllerDisplay()
    if not currentRouteActive or not currentStopIndex or not stopTriggers or #stopTriggers == 0 then
        return
    end

    local routeData = {
        routeId = "RLS",
        routeID = "RLS",
        direction = "",
        tasklist = {}
    }

    local currentStop = stopTriggers[currentStopIndex]
    local triggerName = currentStop:getName() or ""
    routeData.direction = stopDisplayNames[triggerName] or triggerName or string.format("Stop %02d", currentStopIndex)

    -- Append the stop at the given index to the current route's tasklist (waypoints are excluded).
    -- Inserts an entry containing the stop's internal name and display label into `routeData.tasklist`.
    -- @param i The 1-based index of the stop within `stopTriggers`.
    local function addStopToList(i)
        local t = stopTriggers[i]
        local name = t:getName() or ""
        local label = stopDisplayNames[name] or string.format("Stop %02d", i)
        table.insert(routeData.tasklist, {name, label})
    end

    for i = currentStopIndex, #stopTriggers do
        addStopToList(i)
    end
    for i = 1, currentStopIndex - 1 do
        addStopToList(i)
    end

    local vehicle = be:getPlayerVehicle(0)
    if vehicle then
        vehicle:queueLuaCommand(string.format([[
      if controller and controller.onGameplayEvent then
        controller.onGameplayEvent("bus_setLineInfo", %s)
      end
    ]], dumps(routeData)))
    end

    guihooks.trigger('BusDisplayUpdate', routeData)
end

initRoute = function()
    if currentRouteActive and routeInitialized then
        print("[bus] Route already active, skipping reinitialization")
        return
    end

    if career_economyAdjuster then
        local busMultiplier = career_economyAdjuster.getSectionMultiplier("bus") or 1.0
        if busMultiplier == 0 then
            ui_message("Bus routes are currently disabled.", 5, "error", "error")
            print("[bus] Bus multiplier is set to 0, route initialization cancelled")
            return
        end
    end

    local routes = loadRoutesFromJSON()
    if not routes then
        ui_message("No route configuration found for this map.", 5, "error", "error")
        return
    end

    local allTriggers, allWaypoints = collectScenetreeObjects()
    if not next(allTriggers) then
        ui_message("No bus stops found on this map.", 5, "error", "error")
        return
    end

    local selectedRoute, selectedRouteKey = selectRandomRoute(routes)
    if not selectedRoute then
        ui_message("No routes available in configuration.", 5, "error", "error")
        return
    end

    local routeName = selectedRoute.name or selectedRouteKey
    currentRouteName = routeName
    print(
        string.format("[bus] Selected route: %s (%s) with %d stops", routeName, selectedRouteKey, #selectedRoute.stops))

    stopTriggers, routeItems, stopDisplayNames = buildRouteFromConfig(selectedRoute, allTriggers, allWaypoints)
    if #stopTriggers == 0 then
        ui_message("No valid stops found for selected route.", 5, "error", "error")
        return
    end

    currentFinalStopName = stopTriggers[#stopTriggers]:getName() or ""

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then
        return
    end

    currentStopIndex = 1
    consecutiveStops, dwellTimer, accumulatedReward, totalStopsCompleted = 0, nil, 0, 0
    currentRouteActive, routeInitialized, passengersOnboard, routeCooldown = true, true, 0, 0
    tipTotal, roughRide, lastVelocity = 0, 0, nil

    local startStopName = stopTriggers[currentStopIndex]:getName() or "Unknown"
    local targetPos = stopTriggers[currentStopIndex]:getPosition()

    setupRouteNavigation(vehicle, targetPos, 1)

    ui_message(string.format("Bus route '%s' started. Proceed to %s. Route has %d stops.", routeName, startStopName,
        #stopTriggers), 6, "info", "info")

    updateBusControllerDisplay()

    showCurrentStopMarkers()
end

-- Process the active route's current stop: verifies the correct stop trigger, enforces vehicle settling, manages dwell timing, runs boarding/deboarding animation and logic, updates passenger counts, calculates payouts and tips, handles loop completion, and advances navigation to the next stop.
-- @param vehicle The vehicle object (expected player vehicle) used for speed checks and navigation context.
-- @param dtSim Simulation delta time for this update step (may be nil; a default step is used internally).
local function processStop(vehicle, dtSim)
    if not currentRouteActive or not currentStopIndex then
        return
    end
    if routeCooldown > 0 then
        return
    end
    if not stopTriggers or #stopTriggers == 0 then
        return
    end
    if currentStopIndex < 1 or currentStopIndex > #stopTriggers then
        return
    end

    local trigger = getNextTrigger()
    if not trigger then
        return
    end

    local expectedStopName = stopTriggers[currentStopIndex]:getName()
    if expectedStopName and trigger:getName() ~= expectedStopName then
        return
    end

    if currentTriggerName == trigger:getName() then
        if stopIndexWhereBoardingStarted and stopIndexWhereBoardingStarted == currentStopIndex and dwellTimer == nil then
            return
        end

        local velocity = vehicle:getVelocity():length()

        if velocity > 0.5 then
            ui_message("Come to a complete stop before passengers can board.", 2, "info", "info")
            dwellTimer = nil
            stopMonitorActive = false
            stopSettleTimer = 0
            return
        end

        if not stopMonitorActive then
            stopMonitorActive = true
            stopSettleTimer = 0
            ui_message("Please open doors to begin boarding", 2.5, "info", "bus")
            core_vehicleBridge.executeAction(vehicle, 'setFreeze', true)
        else
            stopSettleTimer = stopSettleTimer + (dtSim or 0.033)
        end

        if stopSettleTimer < stopSettleDelay then
            dwellTimer = nil
            return
        end

        if not dwellTimer then
            dwellTimer = 0
            stopIndexWhereBoardingStarted = currentStopIndex
            hideStopMarkers()
            consecutiveStops = consecutiveStops + 1
            totalStopsCompleted = totalStopsCompleted + 1

            local triggerName = trigger:getName() or ""
            local isFinalStop = (triggerName == currentFinalStopName)

            if isFinalStop then
                trueBoarding = 0
                trueDeboarding = passengersOnboard
                dwellDuration = math.max(6, trueDeboarding * 0.6)
            else
                local capacity = M.vehicleCapacity
                local availableSpace = math.max(0, capacity - passengersOnboard)
                trueBoarding = math.random(3, math.min(12, availableSpace))
                trueDeboarding = (passengersOnboard > 0) and math.random(1, math.min(passengersOnboard, 6)) or 0

                local baseIdle = math.random(8, 12)
                local existingDwellCalc = baseIdle + (trueBoarding * 0.8) + (trueDeboarding * 0.5)
                local animationDuration = (trueDeboarding * 2) + (trueBoarding * 2) + baseIdle
                dwellDuration = math.max(existingDwellCalc, animationDuration + 1)
            end

            boardingCoroutine = coroutine.create(function()

                -- Suspends the current coroutine until the given duration (in seconds) has elapsed.
                -- @param duration Number of seconds to wait.
                -- The coroutine advances using the delta time value yielded to it; if no delta is provided, 0.033 seconds is used per iteration.
                local function waitForAnimation(duration)
                    local t = 0
                    while t < duration do
                        local dt = coroutine.yield()
                        t = t + (dt or 0.033)
                    end
                end

                if trueDeboarding > 0 then
                    for i = trueDeboarding, 1, -1 do
                        ui_message(string.format("Stop %d\nDeboarding: %d\nBoarding: 0", currentStopIndex, i), 2, "bus",
                            "bus_anim")
                        waitForAnimation(2)
                    end
                else
                    ui_message(string.format("Stop %d\nDeboarding: 0\nBoarding: 0", currentStopIndex), 1, "bus",
                        "bus_anim")
                end

                if trueBoarding > 0 then
                    for i = 1, trueBoarding do
                        ui_message(string.format("Stop %d\nDeboarding: 0\nBoarding: %d", currentStopIndex, i), 2, "bus",
                            "bus_anim")
                        waitForAnimation(2)
                    end
                else
                    ui_message(string.format("Stop %d\nDeboarding: 0\nBoarding: 0", currentStopIndex), 1, "bus",
                        "bus_anim")
                end

            end)

        end

        dwellTimer = dwellTimer + (dtSim or 0.033)

        if (boardingCoroutine and coroutine.status(boardingCoroutine) == "dead") or (not boardingCoroutine and dwellTimer >= dwellDuration) then
            print(string.format("[bus] Dwell complete at stop %d", currentStopIndex))

            passengersOnboard = math.min(math.max(0, passengersOnboard + trueBoarding - trueDeboarding),
                M.vehicleCapacity)

            local base = 400
            local bonusMultiplier = 1 + (consecutiveStops / #stopTriggers) * 3
            local payout = math.floor(base * bonusMultiplier)

            if career_economyAdjuster then
                local multiplier = career_economyAdjuster.getSectionMultiplier("bus") or 1.0
                payout = math.floor(payout * multiplier + 0.5)
            end

            accumulatedReward = accumulatedReward + payout

            local tipsEarned = 0
            if trueDeboarding > 0 then
                local avgRough = math.max(0, roughRide / math.max(1, dwellDuration))
                local tipPerPassenger = math.max(0, 8 - avgRough) * 2
                tipsEarned = math.floor(tipPerPassenger * trueDeboarding * 40)
                tipTotal = tipTotal + tipsEarned
            end
            print(string.format("[bus] Tips: +%d   TotalTips=%d", tipsEarned, tipTotal))

            roughRide = 0

            dwellTimer = nil
            stopMonitorActive = false
            stopSettleTimer = 0
            stopIndexWhereBoardingStarted = nil
            currentTriggerName = nil

            local triggerName = trigger:getName() or ""
            if triggerName == currentFinalStopName then
                local loopBonus = math.floor(accumulatedReward * 0.5)
                accumulatedReward = accumulatedReward + loopBonus
                local totalPotential = accumulatedReward + tipTotal

                ui_message(string.format(
                    "All passengers unloaded.\nLoop complete! Bonus +$%d (+50%%)\nRoute earnings so far: $%d\nTips: $%d\nTotal potential payout: $%d",
                    loopBonus, accumulatedReward, tipTotal, totalPotential), 6, "info", "info")

                passengersOnboard = 0
                trueBoarding = 0
                trueDeboarding = 0

                routeCooldown = 10
                currentStopIndex = 1
                
                isCalculatingRoute = true
                routeCalcTimer = 0
                
                updateBusControllerDisplay()

                if career_saveSystem and career_saveSystem.saveCurrent then
                    career_saveSystem.saveCurrent()
                end

            else
                local nextStopIndex = math.min((currentStopIndex or 1) + 1, #stopTriggers)
                local nextStopName = stopTriggers[nextStopIndex]:getName() or "Unknown"
                print(string.format("[bus] Moving to next stop: index %d, name %s", nextStopIndex, nextStopName))
                
                local reputationGain = math.floor(payout / 500)
                
                ui_message(string.format("Proceed to Stop %02d\nBase pay: $%d\nTips: $%d\nTotal tips: $%d\nReputation: +%d",
                    nextStopIndex, payout, tipsEarned, tipTotal, reputationGain), 8, "info", "bus_next")
                
                currentStopIndex = nextStopIndex
                isCalculatingRoute = true
                routeCalcTimer = 0
                updateBusControllerDisplay()
            end
        end

    else
        dwellTimer = nil
        stopMonitorActive = false
        stopSettleTimer = 0
    end
end

-- Handle player vehicle switches, updating the active bus and managing route start/stop.
-- If the player leaves the currently active bus, ends the current route and grants the accumulated payout (capped).
-- If the newly entered vehicle is a bus and no route is active, marks it as the active bus, shows a start message, and defers route initialization until vehicle seating capacity is retrieved; if a route is already active, updates the active bus reference without reinitializing.
-- @param oldId The ID of the vehicle the player was previously in (may be nil).
-- @param newId The ID of the vehicle the player has entered (may be nil).
local function onVehicleSwitched(oldId, newId)
    local newVeh = be:getObjectByID(newId)

    if currentRouteActive and activeBusID and oldId == activeBusID then
        local payout = accumulatedReward + tipTotal
        if payout > 100000 then
            payout = 100000
        end
        endRoute("player exited the bus", payout)
    end

    if newVeh and isBus(newVeh) then
        if not currentRouteActive or not routeInitialized then
            activeBusID = newId
            currentLoanerCut = calculateLoanerCut(newId)
            ui_message("Shift started. Welcome in! Drive careful out there.", 10, "info", "info")
            pendingRouteInit = true
            retrievePartsTree()
        else
            activeBusID = newId
            print("[bus] Route already active, not reinitializing")
        end
    end
end

-- Notify the player that the bus extension is ready and log the load event.
-- Displays an on-screen message prompting the player to enter a BUS vehicle and prints a load message to the console.
local function onExtensionLoaded()
    ui_message("Bus module loaded. Enter a BUS vehicle to begin your route.", 3, "info", "info")
    print("[bus] Extension loaded.")
end

-- Perform per-frame bus-route updates: handle loop cooldown, advance boarding animation, track rough ride,
-- and execute core stop processing when the player is driving an active bus route.
-- @param dtReal Wall-clock delta time in seconds (unused by this function).
-- @param dtSim Simulation delta time in seconds; used for route cooldown, boarding coroutine progression,
-- and rough-ride acceleration calculations.
-- @param dtRaw Raw frame delta time in seconds (unused by this function).
local function onUpdate(dtReal, dtSim, dtRaw)
    if isCalculatingRoute then
        routeCalcTimer = routeCalcTimer + (dtSim or 0.033)
        if routeCalcTimer > 0.5 then
            local vehicle = be:getPlayerVehicle(0)

            showNextStopMarker(currentStopIndex)

            if vehicle then
                core_vehicleBridge.executeAction(vehicle, 'setFreeze', false)
            end

            isCalculatingRoute = false
        end
        return
    end

    if routeCooldown > 0 then
        routeCooldown = math.max(0, routeCooldown - (dtSim or 0))
        return
    end

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle or not isBus(vehicle) or not routeInitialized then
        return
    end

    if boardingCoroutine and coroutine.status(boardingCoroutine) ~= "dead" then
        local ok, err = coroutine.resume(boardingCoroutine, dtSim)
        if not ok then
            print(string.format("[bus] Boarding animation coroutine error at stop %d: %s", currentStopIndex or -1,
                tostring(err)))
            boardingCoroutine = nil
        end
    end

    local velocity = vehicle:getVelocity()

    if lastVelocity then
        local deltaVel = velocity - lastVelocity
        local safeDt = (dtSim and dtSim > 0) and dtSim or 0.01
        local accel = deltaVel:length() / safeDt
        local accelThreshold = 3.5

        if accel > accelThreshold then
            roughRide = roughRide + (accel - accelThreshold) * safeDt * 10
        end
    end

    lastVelocity = velocity

    processStop(vehicle, dtSim)
end

-- Handles BeamNG trigger enter/exit events for bus stops, tracking the active stop trigger and canceling dwell when the player leaves.
-- @param data Table describing the trigger event; expected fields:
--   - subjectID (number): vehicle ID associated with the event.
--   - triggerName (string): name of the trigger object (bus stop triggers contain "_bs_").
--   - event (string): either "enter" or "exit".
local function onBeamNGTrigger(data)
    if be:getPlayerVehicleID(0) ~= data.subjectID then
        return
    end
    if gameplay_walk and gameplay_walk.isWalking() then
        return
    end

    if not data.triggerName:find("_bs_") then
        return
    end

    if data.event == "enter" then
        currentTriggerName = data.triggerName
    elseif data.event == "exit" then
        if currentTriggerName == data.triggerName then
            currentTriggerName = nil
            dwellTimer = nil
            stopMonitorActive = false
            stopSettleTimer = 0
        end
    end
end

-- Cleans up and resets the bus module when the extension is unloaded.
-- Clears visual stop markers and navigation markers, cancels any active boarding coroutine,
-- and resets all runtime state (route progress, timers, passenger counts, vehicle parts/capacity, and related flags).
local function onExtensionUnloaded()
    print("[bus] Extension unloading, cleaning up...")

    clearStopMarkers()

    if core_groundMarkers then
        core_groundMarkers.resetAll()
    end

    boardingCoroutine = nil

    currentStopIndex = nil
    stopTriggers = {}
    dwellTimer = nil
    dwellDuration = 10
    consecutiveStops = 0
    currentRouteActive = false
    accumulatedReward = 0
    passengersOnboard = 0
    activeBusID = nil
    routeInitialized = false
    totalStopsCompleted = 0
    routeCooldown = 0
    currentVehiclePartsTree = nil
    stopMonitorActive = false
    stopSettleTimer = 0
    currentTriggerName = nil
    roughRide = 0
    lastVelocity = nil
    tipTotal = 0
    trueBoarding = 0
    trueDeboarding = 0
    currentFinalStopName = nil
    stopIndexWhereBoardingStarted = nil
    pendingRouteInit = false
    isCalculatingRoute = false
    routeCalcTimer = 0
    currentRouteName = nil
    stopDisplayNames = {}
    routeItems = {}
    currentLoanerCut = 0

    M.vehicleCapacity = nil

    print("[bus] Extension unloaded successfully.")
end

M.returnPartsTree = returnPartsTree
M.onVehicleSwitched = onVehicleSwitched
M.onUpdate = onUpdate
M.onBeamNGTrigger = onBeamNGTrigger
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
