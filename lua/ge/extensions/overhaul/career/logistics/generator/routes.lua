-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Logistics generator: road route search and facility distances.
-- Built by career/logistics/generator.lua, which owns the facilities, the generation tick and the public functions.
local part = {}

-- Instance-local closures keep reloaded careers isolated.
function part.new(inputs)
  local api = {}
  local gen = inputs.state.gen
  local distanceBetween = inputs.services.sharedFacilityScanner.getDistanceBetweenLocations

  -- Config ----------------------------------------------------------------------------------------

  -- A background batch yields after this many seconds of search, so a long route never stalls a frame.
  local ROUTE_SLICE = 0.0006
  -- The last few open searches are kept; an older one is dropped and its recorded lengths stay.
  local OPEN_SEARCHES = 4
  local routeClock = os.clockhp or os.clock
  local routeDrivCoeff = {[true] = 1, [false] = 10000}
  local routeDirCoeff = {[true] = 1, [false] = 1}

  -- State -----------------------------------------------------------------------------------------

  local newMinheap = nil
  local routeVec = nil
  local spareTables, spareHeaps = {}, {}

  -- Route state -----------------------------------------------------------------------------------

  function api.getLocationCoordinates(loc)
    if loc.type == "facilityParkingspot" then
      local ps = inputs.callbacks.getParkingSpotByPath(loc.psPath)
      if ps then return ps.pos end
    elseif loc.type == "vehicle" then
      local veh = scenetree.findObjectById(loc.vehId)
      if veh then return veh:getPosition() end
    else
      log("E", "delivery", "no location for " .. dumps(loc))
      return nil
    end
  end

  -- Reuse one graph sweep per start so facility lengths match stock paths without repeating the search.
  local function routeState()
    local gp = map.getGraphpath()
    if gen.routes.graph ~= gp then
      gen.routes = {graph = gp, spots = {}, targetIndex = {}, targetCount = 0, starts = {}, open = {}, spotsResolved = false}
    end
    return gen.routes
  end

  local function closestRoad(spot)
    if spot and spot.pos then return map.findClosestRoad(spot.pos) end
  end

  local function spotRoad(state, psPath)
    local road = state.spots[psPath]
    if road ~= nil then return road end
    local ps = gen.parkingSpotsByPath[psPath]
    local name, _, dist = closestRoad(ps)
    road = name and {node = name, dist = tonumber(dist) or 0} or false
    state.spots[psPath] = road
    if road and not state.targetIndex[name] then
      state.targetCount = state.targetCount + 1
      state.targetIndex[name] = state.targetCount
    end
    return road
  end

  local function yieldIfSlow(sliceStart, workLimit)
    if not workLimit and routeClock() - sliceStart < ROUTE_SLICE then return sliceStart end
    inputs.callbacks.yieldGeneration()
    return routeClock()
  end

  -- Search tables ---------------------------------------------------------------------------------
  -- Search tables are sized to the whole graph; closed searches hand them back cleared instead of leaving garbage.
  local function takeTable()
    return table.remove(spareTables) or {}
  end

  local function releaseSearch(search)
    for _, key in ipairs({'road', 'minParent', 'minCost', 'along'}) do
      if #spareTables < 4 * (OPEN_SEARCHES + 1) then
        table.clear(search[key])
        spareTables[#spareTables + 1] = search[key]
      end
    end
    if #spareHeaps < OPEN_SEARCHES + 1 then
      search.que:clear()
      spareHeaps[#spareHeaps + 1] = search.que
    end
  end

  -- Searches --------------------------------------------------------------------------------------
  -- Relaxes the edges out of a settled node, following getFilteredPath's costs.
  local function expandNode(search, node, cost)
    local graph, road, minParent, minCost, que = search.graph, search.road, search.minParent, search.minCost, search.que
    for child, data in pairs(graph[node]) do
      if road[child] == nil then
        local currentChildCost = minCost[child]
        local newChildCost = cost + data.len * routeDirCoeff[data.oneWay and data.inNode == child] * routeDrivCoeff[data.drivability > 0]
        if currentChildCost == nil or currentChildCost > newChildCost then
          que:insert(newChildCost, child)
          minParent[child] = node
          minCost[child] = newChildCost
        end
      end
    end
  end

  local function openSearch(state, record, start)
    local mapData = map.getMap()
    newMinheap = newMinheap or require('graphpath').newMinheap
    local minParent = takeTable()
    minParent[start] = false
    local search = {graph = state.graph.graph, nodes = mapData and mapData.nodes, knownTargets = state.targetCount,
      road = takeTable(), minParent = minParent, minCost = takeTable(), along = takeTable(),
      que = table.remove(spareHeaps) or newMinheap(), cost = 0, node = start}
    record.search = search
    local open = state.open
    open[#open + 1] = record
    if #open > OPEN_SEARCHES then
      local dropped = table.remove(open, 1)
      releaseSearch(dropped.search)
      dropped.search = nil
    end
    return search
  end

  local function closeSearch(state, record, knownTargets)
    record.complete = knownTargets or record.search.knownTargets
    releaseSearch(record.search)
    record.search = nil
    for i, item in ipairs(state.open) do
      if item == record then table.remove(state.open, i) break end
    end
  end

  -- The length to a settled node: its parent's length plus the edge between them; false when a position is missing.
  local function settledLength(search, node)
    local parent = search.minParent[node]
    if parent == false then
      -- facilityScanner only reads positions for path segments, and needs the node table.
      return search.nodes and 0 or false
    end
    local length = search.along[parent]
    local a, b = search.nodes and search.nodes[parent], search.nodes and search.nodes[node]
    if length and a and a.pos and b and b.pos then
      routeVec:set(a.pos)
      routeVec:setSub(b.pos)
      return length + routeVec:length()
    end
    return false
  end

  -- Stop after each requested goal so later requests resume the same ordered graph search.
  local function settleNode(state, record, search, node, cost, goal)
    search.road[node] = search.minParent[node]
    local length = settledLength(search, node)
    search.along[node] = length
    local index = state.targetIndex[node]
    if index and record.lengths[index] == nil then
      record.lengths[index] = length
      state.persistenceDirty = true
      record.recorded = record.recorded + 1
      -- Every facility road node is settled: the rest of the graph cannot change any recorded length.
      if record.recorded >= state.targetCount then
        closeSearch(state, record, state.targetCount)
        return true
      end
    end
    if node == goal then
      search.cost, search.node, search.expandPending = cost, node, true
      return true
    end
    expandNode(search, node, cost)
    return false
  end

  -- A sliced request must abandon stale graph state after yielding.
  local function searchTo(state, start, goal, sliced)
    local gp = state.graph
    local record = state.starts[start]
    if not record then
      record = {lengths = {}, recorded = 0}
      state.starts[start] = record
    end
    if state.graph.graph[start] == nil then
      record.complete = state.targetCount
      return record
    end
    local search = record.search or openSearch(state, record, start)
    local graph = search.graph
    routeVec = routeVec or vec3()
    local cost, node = search.cost, search.node
    if search.expandPending then
      -- The previous request stopped right after settling its goal; carry on as one uninterrupted search.
      search.expandPending = nil
      expandNode(search, node, cost)
      cost, node = search.que:pop()
    end
    local sliceStart, pops = routeClock(), 0
    while cost do
      if search.road[node] == nil and settleNode(state, record, search, node, cost, goal) then return record end
      cost, node = search.que:pop()
      pops = pops + 1
      if sliced and pops % 128 == 0 then
        search.cost, search.node = cost, node
        sliceStart = yieldIfSlow(sliceStart, true)
        if gen.routes ~= state or map.getGraphpath() ~= gp or gp.graph ~= graph then return nil end
        -- Another request may have advanced or dropped this search while it waited.
        if record.search ~= search then return searchTo(state, start, goal, sliced) end
        cost, node = search.cost, search.node
      end
    end
    closeSearch(state, record)
    return record
  end

  -- Facility distances ----------------------------------------------------------------------------
  -- Resolves every facility parking spot once per road graph, so a full search records all facility road nodes.
  local function resolveAllSpots(state, sliced)
    if state.spotsResolved then return true end
    local sliceStart, resolved = routeClock(), 0
    for psPath in pairs(gen.parkingSpotsByPath) do
      spotRoad(state, psPath)
      resolved = resolved + 1
      if sliced then sliceStart = yieldIfSlow(sliceStart, resolved % 16 == 0) end
      if gen.routes ~= state then return false end
    end
    state.spotsResolved = true
    require('overhaul/career/logistics/generator/routeCache').load(state)
    return true
  end

  local function inGenerationBatch()
    return gen.runningGenerationBatch and gen.generationBatch ~= nil and coroutine.running() == gen.generationBatch.thread
  end

  -- The recorded length to goalIndex: false when it is unreachable, nil when it is not known yet.
  local function knownLength(record, goalIndex)
    if not record or not goalIndex then return nil end
    local length = record.lengths[goalIndex]
    if length ~= nil then return length end
    if record.complete and goalIndex <= record.complete then return false end
    return nil
  end

  -- Unresolved route lengths fall back to the shared facility scanner.
  local function spotDistance(loc1, loc2, pos1, pos2)
    local state = routeState()
    if state.graph == nil then return nil end
    local sliced = inGenerationBatch()
    if not resolveAllSpots(state, sliced) then return nil end
    local roadA, roadB = spotRoad(state, loc1.psPath), spotRoad(state, loc2.psPath)
    if not roadA or not roadB then return pos1:distance(pos2), false end
    local length = knownLength(state.starts[roadA.node], state.targetIndex[roadB.node])
    if length == nil then
      local record = searchTo(state, roadA.node, roadB.node, sliced)
      if not record then return nil end
      length = knownLength(record, state.targetIndex[roadB.node])
      if length == nil then return nil end
    end
    if not length then return pos1:distance(pos2), false end
    return length + roadA.dist + roadB.dist, true
  end

  local function initialSpotDistance(loc1, loc2, pos1, pos2)
    if loc1.type == "facilityParkingspot" then return spotDistance(loc1, loc2, pos1, pos2) end
  end

  function api.getDistanceBetweenFacilities(loc1, loc2)
    if not loc1 or not loc2 then return 0, false end
    if loc2.type == "facilityParkingspot" then
      local distanceKey = string.format("%s-%s-%s-%s", loc1.facId, loc1.psPath, loc2.facId, loc2.psPath)
      if gen.distanceCache[distanceKey] ~= nil then
        return gen.distanceCache[distanceKey], true
      end

      local pos1 = api.getLocationCoordinates(loc1)
      local pos2 = api.getLocationCoordinates(loc2)
      if not pos1 or not pos2 then return 0, false end
      local distance, routeReliable = initialSpotDistance(loc1, loc2, pos1, pos2)
      if distance == nil then
        distance, routeReliable = distanceBetween(pos1, pos2)
      end
      if routeReliable then
        gen.distanceCache[distanceKey] = distance
      end
      return distance, routeReliable
    elseif loc2.type == "multi" then
      -- The median of the distances to each destination.
      local dists = {}
      local iHalf = 0
      for i, loc in ipairs(loc2.destinations) do
        local distance, routeReliable = api.getDistanceBetweenFacilities(loc1, loc)
        dists[i] = {distance = distance, routeReliable = routeReliable}
        iHalf = math.ceil(i/2)
      end
      table.sort(dists, function(a, b) return a.distance < b.distance end)
      local median = dists[iHalf]
      return median and median.distance or 0, median and median.routeReliable or false
    end
    return 0, false
  end

  -- Public API ------------------------------------------------------------------------------------

  api.distanceBetween = distanceBetween
  return api
end

return part
