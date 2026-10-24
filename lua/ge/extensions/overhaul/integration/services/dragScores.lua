-- Owns drag geometry, level-lifetime navigation waypoints and saved dial times.
-- Read geometry helpers and waypoint ownership, loaders, dial/history storage, then lifecycle hooks.
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/gameplay/drag/saveSystem.lua (BeamNG 0.40).

local M = {}
local levelData = require("overhaul/lib/world/levelData")
M.dependencies = {"overhaul_shell_patches"}
-- SaveStore keys over the files this module writes today (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "events.dragDialTimes", owner = "overhaul_integration_services_dragScores", files = {"dragDialTimes.json"}, phase = "profile", required = true},
})
local logTag = "drag_save_system"
local dialTimes
local profilePath

local function getDialData()
  if not dialTimes then
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    profilePath = savePath
    dialTimes = savePath and jsonReadFile(savePath .. "/dragDialTimes.json") or {}
    if type(dialTimes) ~= "table" then dialTimes = {} end
  end
  return dialTimes
end

M.DEFAULT_TIMERS = {
  { id = "reactionTime", label = "Reaction Time", labelKey = "ui.drag.winnerBy.reactionTime", shortLabel = "R/T", type = "distanceTimer", distance = 0.178, important = false },
  { id = "time_60", label = "60 ft", labelKey = "ui.drag.winnerBy.time60", shortLabel = "60'", type = "distanceTimer", distance = 18.288, important = false },
  { id = "time_330", label = "330 ft", labelKey = "ui.drag.winnerBy.time330", shortLabel = "330'", type = "distanceTimer", distance = 100.584, important = false },
  { id = "time_1_8", label = "1/8 mile", labelKey = "ui.drag.winnerBy.time18", shortLabel = "1/8", type = "distanceTimer", distance = 201.168, important = false },
  { id = "time_1000", label = "1000 ft", labelKey = "ui.drag.winnerBy.time1000", shortLabel = "1000'", type = "distanceTimer", distance = 304.8, important = false },
  { id = "time_1_4", label = "1/4 mile", labelKey = "ui.drag.winnerBy.time14", shortLabel = "1/4", type = "distanceTimer", distance = 402.336, important = true },
  { id = "velAt_1_8", label = "Speed at 1/8 mile", labelKey = "ui.drag.winnerBy.speedAt18", type = "velocity", distance = 201.168, important = false },
  { id = "velAt_1_4", label = "Speed at 1/4 mile", labelKey = "ui.drag.winnerBy.speedAt14", type = "velocity", distance = 402.336, important = false },
}

local function createDefaultTimers()
  return deepcopy(M.DEFAULT_TIMERS), "time_1_4"
end

-- Auxiliary functions

local function getCurrentLevelDragPath()
  local levelName = getCurrentLevelIdentifier()
  if not levelName then
    log('E', logTag, 'Could not determine current level')
    return nil
  end
  return '/levels/' .. levelName .. '/dragstrips/'
end

local function normalizeTimersConfig(timersArray)
  if not timersArray or type(timersArray) ~= "table" or #timersArray == 0 then
    return nil, nil
  end
  local out = {}
  local importantId = nil
  for i, t in ipairs(timersArray) do
    if t and (t.type == "distanceTimer" or t.type == "velocity") and type(t.distance) == "number" then
      local id = t.id and tostring(t.id) ~= "" and t.id or ("timer_" .. i)
      local important = t.important == true
      if important and not importantId then
        importantId = id
      end
      table.insert(out, {
        id = id,
        label = t.label and tostring(t.label) or id,
        labelKey = t.labelKey,
        type = t.type,
        distance = t.distance,
        important = important and (importantId == id),
      })
    end
  end
  if #out == 0 then return nil, nil end
  if not importantId and #out > 0 then
    out[1].important = true
    importantId = out[1].id
  end
  return out, importantId
end

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function safeVec3(t)
  if not t or (type(t) ~= "table" and type(t) ~= "cdata" and type(t) ~= "userdata") then return nil end
  if not finite(t.x) or not finite(t.y) or not finite(t.z) then return nil end
  return vec3(t.x, t.y, t.z)
end

local function safeQuat(t)
  if not t or (type(t) ~= "table" and type(t) ~= "cdata" and type(t) ~= "userdata") then return nil end
  if not finite(t.x) or not finite(t.y) or not finite(t.z) or not finite(t.w) then return nil end
  if t.x == 0 and t.y == 0 and t.z == 0 and t.w == 0 then return nil end
  return quat(t.x, t.y, t.z, t.w)
end

-- Presentation data authored on a strip (lane light bindings, tree policy, event binding) survives normalization.
local function copyLights(lights)
  if type(lights) ~= "table" then return nil end
  local copy = {}
  for slot, name in pairs(lights) do
    if type(slot) == "string" and type(name) == "string" then copy[slot] = name end
  end
  return next(copy) and copy or nil
end

-- Field-level overlay: an override group changes only the fields it names.
local function overlayPrefabs(base, overrides)
  if type(overrides) ~= "table" then return base end
  for group, fields in pairs(overrides) do
    if type(fields) == "table" and type(base[group]) == "table" then
      for field, value in pairs(fields) do base[group][field] = value end
    else
      base[group] = fields
    end
  end
  return base
end

local function stringOrNil(value)
  return type(value) == "string" and value ~= "" and value or nil
end

local function waypointTransform(tf)
  if type(tf) ~= "table" then return nil end
  local pos = safeVec3(tf.position or tf.pos)
  local rot = safeQuat(tf.rotation or tf.rot)
  local scl = safeVec3(tf.scale or tf.scl)
  if not pos or not rot or not scl then return nil end
  return {
    position = pos, rotation = rot, scale = scl,
    pos = vec3(pos.x, pos.y, pos.z), rot = rot, scl = scl,
    x = rot * vec3(scl.x, 0, 0), y = rot * vec3(0, scl.y, 0), z = rot * vec3(0, 0, scl.z),
  }
end

local function deserializeZone(data)
  if not data or not data.vertices or #data.vertices < 3 then return nil end
  local ZoneClass = require('/lua/ge/extensions/gameplay/sites/zone')
  local zone = ZoneClass(nil, data.name or "Zone")
  zone:onDeserialized(data)
  return zone
end

-- JSON owns geometry unless the row explicitly selects a named scene waypoint as its authority.
local function waypointEntryFromStripJson(waypoint, logSuffix)
  local transform = type(waypoint) == "table" and waypointTransform(waypoint.transform)
  if not transform or type(waypoint.type) ~= "string" or waypoint.type == "" then
    log("E", logTag, "Drag strip unavailable: waypoint has missing or malformed geometry/type" .. (logSuffix or ""))
    return nil
  end
  if (waypoint.sceneName ~= nil and (type(waypoint.sceneName) ~= "string" or waypoint.sceneName == ""))
    or (waypoint.sceneAuthority ~= nil and type(waypoint.sceneAuthority) ~= "boolean")
    or (waypoint.sceneAuthority and not waypoint.sceneName) then
    log("E", logTag, "Drag strip unavailable: invalid explicit scene binding" .. (logSuffix or ""))
    return nil
  end
  return {
    id = waypoint.id, name = waypoint.name,
    sceneName = waypoint.sceneName, sceneAuthority = waypoint.sceneAuthority,
    transform = transform, waypoint = waypoint.waypoint,
  }
end

--- Canonical authoring name, retained for editors and existing callers.
M.laneWaypointSceneName = function(stripId, wpType, laneIndex)
  return tostring(stripId) .. "_wp_" .. tostring(wpType) .. "_" .. tostring(laneIndex)
end

local runtimeGroups = {}

local function rebuildNavgraph()
  if not map or not map.reset then return end
  local ok, err = pcall(map.reset)
  if not ok then log("E", logTag, "map.reset() (navgraph rebuild) failed: " .. tostring(err)) end
end

-- Only these groups and their children belong to this service; authored objects stay with the level.
M.unloadDragStripWaypoints = function()
  local changed = false
  for stripId, owned in pairs(runtimeGroups) do
    local group = scenetree.findObjectById(owned.groupId)
    if group then group:delete(); changed = true end
    runtimeGroups[stripId] = nil
  end
  if changed then rebuildNavgraph() end
end

local function sceneWaypoint(stripId, waypointType, laneIndex, entry, runtimeId)
  local canonical = laneIndex and M.laneWaypointSceneName(stripId, waypointType, laneIndex)
    or stripId .. "_" .. waypointType
  for _, candidate in ipairs({canonical, entry.name or false, entry.sceneName or false}) do
    local obj = candidate and scenetree.findObject(candidate)
    if obj and obj:getClassName() == "BeamNGWaypoint" and obj:getID() ~= runtimeId then return obj end
  end
end

local function syncDragWaypointEntry(dragData, waypointType, laneIndex, entry, readOnly, created)
  if entry.sceneAuthority then
    local obj = scenetree.findObject(entry.sceneName)
    if not obj or obj:getClassName() ~= "BeamNGWaypoint" then
      error("Explicit scene waypoint is unavailable: " .. tostring(entry.sceneName), 0)
    end
    local tf = waypointTransform({position = obj:getPosition(), rotation = quat(obj:getRotation()), scale = obj:getScale()})
    if not tf then error("Explicit scene waypoint has malformed geometry: " .. entry.sceneName, 0) end
    entry.name, entry.transform = entry.sceneName, tf
    return false
  end

  local stripId = dragData.strip.id
  local key = tostring(laneIndex or 0) .. ":" .. waypointType
  local owned = runtimeGroups[stripId]
  local runtimeId = owned and owned.waypoints[key]
  local scene = sceneWaypoint(stripId, waypointType, laneIndex, entry, runtimeId)
  if scene then
    -- AI can target the map waypoint while timing and staging keep authored JSON geometry.
    entry.name = scene:getName()
    return false
  end
  if readOnly then return false end

  local group = owned and scenetree.findObjectById(owned.groupId)
  if not group then
    group = createObject("SimGroup")
    group.canSave = false
    owned = {waypoints = {}}
    created.group, created.stripId = group, stripId
    runtimeGroups[stripId] = owned
    group:registerObject("")
    owned.groupId = group:getID()
    scenetree.MissionGroup:addObject(group)
  end
  local obj = runtimeId and scenetree.findObjectById(runtimeId)
  local changed = not obj
  if not obj then
    obj = createObject("BeamNGWaypoint")
    obj.canSave = false
    created[#created + 1] = {owned = owned, key = key, object = obj}
    obj:registerObject("")
    group:addObject(obj)
    owned.waypoints[key] = obj:getID()
    local name = entry.sceneName
    if not name or scenetree.findObject(name) then name = "overhaul_drag_wp_" .. obj:getID() end
    obj:setName(name)
  end
  local tf = assert(waypointTransform(entry.transform), "Drag waypoint has malformed geometry")
  if not changed then
    local pos, scl = obj:getPosition(), obj:getScale()
    changed = pos.x ~= tf.position.x or pos.y ~= tf.position.y or pos.z ~= tf.position.z
      or scl.x ~= tf.scale.x or scl.y ~= tf.scale.y or scl.z ~= tf.scale.z
  end
  obj:setPosRot(tf.position.x, tf.position.y, tf.position.z,
    tf.rotation.x, tf.rotation.y, tf.rotation.z, tf.rotation.w)
  obj:setScale(tf.scale)
  entry.name, entry.transform = obj:getName(), tf
  return changed
end

-- Stable strip/lane/type keys survive the stock core's deep copies and repeated strip visits.
M.syncDragStripWaypointsWithSceneTree = function(dragData, readOnly)
  if not dragData or not dragData.strip then return false end
  local changed, created = false, {}
  local ok, err = pcall(function()
    for laneIndex, lane in ipairs(dragData.strip.lanes or {}) do
      for waypointType, entry in pairs(lane.waypoints or {}) do
        changed = syncDragWaypointEntry(dragData, waypointType, laneIndex, entry, readOnly, created) or changed
      end
      if lane.waypoints.stage and lane.waypoints.endLine then
        local sp = lane.waypoints.stage.transform.position
        local ep = lane.waypoints.endLine.transform.position
        if sp:squaredDistance(ep) == 0 then error("Drag stage and endLine coincide", 0) end
        lane.stageToEndNormalized = (ep - sp):normalized()
      end
    end
    for waypointType, entry in pairs(dragData.strip.waypoints or {}) do
      changed = syncDragWaypointEntry(dragData, waypointType, nil, entry, readOnly, created) or changed
    end
  end)
  if not ok then
    -- Failed allocations never join the level cache or remove a prior successful load.
    for _, pending in ipairs(created) do
      pending.object:delete()
      pending.owned.waypoints[pending.key] = nil
    end
    if created.group then
      created.group:delete()
      runtimeGroups[created.stripId] = nil
    end
    log("E", logTag, "Drag strip unavailable: " .. tostring(err))
    return false
  end
  if changed then rebuildNavgraph() end
  return true
end

local function findAutoStopNode(mapData, stagePoint, endPoint, minDist)
  local path = mapData:getPath(stagePoint, endPoint)
  local thisEndPoint, thisStagePoint = endPoint, path[#path - 1]
  if not thisStagePoint then return nil end

  local stopName
  local dist = 0
  repeat
    local thisStop
    local maxDir = 0.966  -- approx 15 degrees
    local thisStagePointPos, thisEndPointPos = mapData:getEdgePositions(thisStagePoint, thisEndPoint)
    local dirVec = thisEndPointPos - thisStagePointPos; dirVec:normalize()
    for node in pairs(mapData.graph[thisEndPoint]) do
      if node ~= thisStagePoint then
        local _, nodePos = mapData:getEdgePositions(thisEndPoint, node)
        local nodeDir = nodePos - thisEndPointPos; nodeDir:normalize()
        local dir = nodeDir:dot(dirVec)
        if dir > maxDir then
          thisStop = node
          maxDir = dir
        end
      end
    end
    if not thisStop then break end
    stopName = thisStop
    thisEndPoint, thisStagePoint = thisStop, thisEndPoint
    dist = dist + mapData.positions[thisEndPoint]:distance(mapData.positions[thisStagePoint])
  until dist >= minDist

  return stopName
end

--- Precomputes each lane's AI stopping point once, at drag data setup time, instead of walking the
-- navgraph on every AI racer's stop phase. Only needed as a fallback when the strip has no explicit
-- strip-level drag_stop waypoint; skipped entirely otherwise.
M.resolveAutoStopWaypoints = function(dragData)
  if not dragData or not dragData.strip or not dragData.strip.lanes then return end

  local wps = dragData.strip.waypoints
  if wps and wps.drag_stop and wps.drag_stop.name then return end

  local mapData = map.getGraphpath()
  if not mapData then return end

  for _, lane in ipairs(dragData.strip.lanes) do
    local stageLine = lane.waypoints and lane.waypoints.stage
    local endLine = lane.waypoints and lane.waypoints.endLine
    if stageLine and endLine then
      local ok, stopName = pcall(findAutoStopNode, mapData, stageLine.name, endLine.name, 350)
      lane.autoStopName = ok and stopName or nil
    end
  end
end

-- Functions called from outside

--- Returns path to current level's dragstrips folder, or nil.
M.getCurrentLevelDragPath = function()
  return getCurrentLevelDragPath()
end

--- Loads full drag race data from a strip file path (strip + lanes, waypoints, phases).
-- stripId: path to the strip JSON file
M.loadCompleteDragRaceData = function(stripId, readOnly)
  -- Stock jsonReadFile returns nil for a missing file and traps decode errors; the pcall covers only its native read, which cannot be proven non-throwing.
  local ok, stripData = pcall(jsonReadFile, stripId)
  if not ok or type(stripData) ~= "table" then
    log('E', logTag, 'Failed to load strip file: ' .. tostring(stripId) .. (not ok and (' — ' .. tostring(stripData)) or ''))
    return nil
  end

  if type(stripData.id) ~= "string" or stripData.id == "" or type(stripData.lanes) ~= "table" then
    log('E', logTag, 'Drag strip unavailable: missing id or lanes in ' .. tostring(stripId))
    return nil
  end

  local completeData = {
    strip = {
      id = stripData.id,
      name = stripData.name,
      description = stripData.description,
      endCamera = stripData.endCamera,
      lanes = {},
      waypoints = {},
      stripZone = nil
    },
    racers = {},
    phases = {
      { name = "stage", dependency = true, startedOffset = 0 },
      { name = "countdown", dependency = true, startedOffset = 0 },
      { name = "race", dependency = false, startedOffset = 0 },
      { name = "stop", dependency = false, startedOffset = 0 },
    },
    prefabs = {
      christmasTree = { isUsed = false, treeType = ".500" },
      displaySign = { isUsed = false },
      paths = { isUsed = false },
      decorations = { isUsed = false },
    },
    dragType = "headsUpRace",
    context = "freeroam",
    canBeReseted = true,
    canBeTeleported = true,
    isStarted = false,
    isCompleted = false,
  }

  overlayPrefabs(completeData.prefabs, stripData.prefabs)
  completeData.eventId = stringOrNil(stripData.eventId)

  if stripData.stripZone then
    completeData.strip.stripZone = deserializeZone(stripData.stripZone)
  end

  if stripData.lanes then
    for _, lane in ipairs(stripData.lanes) do
      if type(lane) ~= "table" or (lane.waypoints ~= nil and type(lane.waypoints) ~= "table") then
        log('E', logTag, 'Drag strip unavailable: malformed lane or waypoints')
        return nil
      end
      local completeLane = {
        id = lane.id,
        shortName = lane.shortName,
        longName = lane.longName,
        color = lane.color,
        laneOrder = lane.laneOrder,
        lights = copyLights(lane.lights),
        waypoints = {},
        boundary = {},
      }

      if lane.waypoints then
        for _, waypoint in ipairs(lane.waypoints) do
          local entry = waypointEntryFromStripJson(waypoint, " in strip: " .. tostring(stripData.id or stripId))
          if not entry then return nil end
          completeLane.waypoints[waypoint.type] = entry
        end
      end

      if completeLane.waypoints.stage and completeLane.waypoints.endLine then
        local stagePos = completeLane.waypoints.stage.transform.position
        local endPos = completeLane.waypoints.endLine.transform.position
        completeLane.stageToEndNormalized = (endPos - stagePos):normalized()
      else
        log('E', logTag, 'Drag strip unavailable: lane requires stage and endLine: ' .. tostring(lane.id))
        return nil
      end

      if type(lane.boundary) == "table" and lane.boundary.transform then
        if type(lane.boundary.transform) ~= "table" then
          log('E', logTag, 'Drag strip unavailable: malformed lane boundary transform')
          return nil
        end
        local bPos = safeVec3(lane.boundary.transform.position)
        local bRot = safeQuat(lane.boundary.transform.rotation)
        local bScl = safeVec3(lane.boundary.transform.scale)
        if bPos and bRot and bScl then
          completeLane.boundary = {
            transform = { position = bPos, rotation = bRot, scale = bScl }
          }
        else
          log('E', logTag, 'Drag strip unavailable: malformed boundary for lane: ' .. tostring(lane.id))
          return nil
        end
      end

      if lane.zone then
        completeLane.zone = deserializeZone(lane.zone)
      end

      table.insert(completeData.strip.lanes, completeLane)
    end
  end

  if stripData.waypoints then
    if type(stripData.waypoints) ~= "table" then
      log('E', logTag, 'Drag strip unavailable: malformed strip waypoints')
      return nil
    end
    for _, waypoint in ipairs(stripData.waypoints) do
      local entry = waypointEntryFromStripJson(waypoint, " (strip-level) in strip: " .. tostring(stripData.id or stripId))
      if not entry then return nil end
      completeData.strip.waypoints[waypoint.type] = entry
    end
  end

  completeData.timers, completeData.importantTimerId = createDefaultTimers()
  if #completeData.strip.lanes == 0 then
    log('E', logTag, 'Drag strip unavailable: no lanes in ' .. tostring(stripId))
    return nil
  end
  if not M.syncDragStripWaypointsWithSceneTree(completeData, readOnly) then return nil end
  return completeData
end

--- Loads drag strip data from file path. readOnly validates scene bindings without allocating waypoints.
-- filepath: path to JSON file
M.loadDragStripData = function(filepath, readOnly)
  if not filepath then
    log('E', logTag, 'No filepath provided for loading drag strip data')
    return nil
  end

  -- Stock jsonReadFile returns nil for a missing file and traps decode errors; the pcall covers only its native read, which cannot be proven non-throwing.
  local ok, data = pcall(jsonReadFile, filepath)
  if not ok or type(data) ~= "table" then
    log('E', logTag, 'Failed to read drag strip data file: ' .. tostring(filepath) .. (not ok and (' — ' .. tostring(data)) or ''))
    return nil
  end

  if data.stripId then
    local level = filepath:match("^/?levels/([^/]+)/") or getCurrentLevelIdentifier()
    local stripFile = (level or type(data.stripId) == "string" and data.stripId:sub(1, 1) == "/")
      and levelData.assetPath(level, data.stripId)
    local stripData = stripFile and M.loadCompleteDragRaceData(stripFile, readOnly)
    if stripData then
      stripData.id = data.id
      stripData.dragType = data.dragType or stripData.dragType
      stripData.context = data.context or stripData.context
      stripData.phases = data.phases or stripData.phases
      overlayPrefabs(stripData.prefabs, data.prefabs)
      stripData.eventId = stringOrNil(data.eventId) or stripData.eventId
      stripData.canBeReseted = data.canBeReseted ~= nil and data.canBeReseted or stripData.canBeReseted
      stripData.canBeTeleported = data.canBeTeleported ~= nil and data.canBeTeleported or stripData.canBeTeleported
      local normTimers, importantId = normalizeTimersConfig(data.timers)
      if normTimers and #normTimers > 0 then
        stripData.timers = normTimers
        stripData.importantTimerId = importantId
      else
        stripData.timers, stripData.importantTimerId = createDefaultTimers()
      end
      return stripData
    else
      log('E', logTag, 'Failed to load complete drag race data')
      return nil
    end
  end

  return M.convertLegacyData(data, readOnly)
end

--- Converts legacy drag strip format to current strip/lanes/waypoints structure.
-- legacyData: table in old format
M.convertLegacyData = function(legacyData, readOnly)
  if type(legacyData) ~= "table" then
    log('E', logTag, 'No legacy data to convert')
    return nil
  end
  if type(legacyData.strip) ~= "table" or type(legacyData.strip.lanes) ~= "table"
    or (legacyData.stripInfo ~= nil and type(legacyData.stripInfo) ~= "table") then
    log('E', logTag, 'Legacy drag strip unavailable: malformed strip or lanes')
    return nil
  end

  local convertedData = {
    strip = {
      id = legacyData.stripInfo and legacyData.stripInfo.id or "legacy_strip",
      name = legacyData.stripInfo and legacyData.stripInfo.stripName or "Legacy Strip",
      description = "Converted from legacy format",
      lanes = {},
      waypoints = {},
    },
    dragType = legacyData.dragType or "",
    context = legacyData.context or "",
    phases = legacyData.phases or {},
    prefabs = legacyData.prefabs or {},
    canBeReseted = legacyData.canBeReseted or false,
    canBeTeleported = legacyData.canBeTeleported or false,
    stripInfo = legacyData.stripInfo or {},
    eventId = stringOrNil(legacyData.eventId),
  }

  if legacyData.strip and legacyData.strip.lanes then
    for i, lane in ipairs(legacyData.strip.lanes) do
      if type(lane) ~= "table" or (lane.waypoints ~= nil and type(lane.waypoints) ~= "table") then
        log('E', logTag, 'Legacy drag strip unavailable: malformed lane or waypoints')
        return nil
      end
      local convertedLane = {
        id = "legacy_lane_" .. i,
        shortName = lane.shortName or ("Lane " .. i),
        longName = lane.longName or ("Lane " .. i),
        color = lane.color or "blue",
        laneOrder = lane.laneOrder or i,
        lights = copyLights(lane.lights),
        waypoints = {},
        boundary = lane.boundary or {},
      }
      if lane.boundary and lane.boundary.transform then
        local tf = waypointTransform(lane.boundary.transform)
        if not tf then
          log('E', logTag, 'Legacy drag strip unavailable: malformed lane boundary')
          return nil
        end
        convertedLane.boundary = {transform = tf}
      end
      if lane.waypoints then
        for waypointType, waypoint in pairs(lane.waypoints) do
          if type(waypoint) ~= "table" then
            log('E', logTag, 'Legacy drag strip unavailable: malformed waypoint')
            return nil
          end
          local entry = waypointEntryFromStripJson({
            type = waypointType, name = waypoint.name, transform = waypoint.transform,
            sceneName = waypoint.sceneName, sceneAuthority = waypoint.sceneAuthority,
            waypoint = waypoint.waypoint or {speed = 5, mode = "limit"},
          }, " in legacy strip: " .. tostring(convertedData.strip.id))
          if not entry then return nil end
          convertedLane.waypoints[waypointType] = entry
        end
      end
      if not convertedLane.waypoints.stage or not convertedLane.waypoints.endLine then
        log('E', logTag, 'Legacy drag strip unavailable: lane requires stage and endLine')
        return nil
      end
      table.insert(convertedData.strip.lanes, convertedLane)
    end
  end

  convertedData.timers, convertedData.importantTimerId = createDefaultTimers()
  if #convertedData.strip.lanes == 0 then
    log('E', logTag, 'Legacy drag strip unavailable: no lanes')
    return nil
  end
  if not M.syncDragStripWaypointsWithSceneTree(convertedData, readOnly) then return nil end
  return convertedData
end

--- Saves dial times and optional timeslip history for playable racers.
-- dragData: current drag data, timeslip: optional timeslip table to save to history
M.saveDialTimes = function(dragData, timeslip)
  if not dragData or not dragData.racers then
    log('E', logTag, 'No drag data or racers to save dial times')
    return
  end

  local dialTimes = getDialData()
  local importantId = dragData.importantTimerId or "time_1_4"

  for vehId, racer in pairs(dragData.racers) do
    local importantTimer = racer.timers and racer.timers[importantId]
    if importantTimer and racer.isPlayable then
      local timesKey = M.generateHashFromFile(vehId)
      local currentTime = importantTimer.value or 10
      if not dialTimes[timesKey] then
        dialTimes[timesKey] = { time_1_4 = currentTime, history = {} }
      elseif not dialTimes[timesKey].history then
        dialTimes[timesKey].history = {}
      end
      local prevBest = dialTimes[timesKey][importantId] or dialTimes[timesKey].time_1_4 or 10
      if currentTime < prevBest then
        dialTimes[timesKey][importantId] = currentTime
        dialTimes[timesKey].time_1_4 = currentTime
      end
      if timeslip then
        local historyEntry = deepcopy(timeslip)
        historyEntry.stripId = dragData.strip and dragData.strip.id or "unknown"
        if timeslip.stripInfo and timeslip.stripInfo.tree then
          historyEntry.tree = timeslip.stripInfo.tree
        end
        if historyEntry.racerInfos and dragData.racers then
          for _, racerInfo in ipairs(historyEntry.racerInfos) do
            for rVehId, rRacer in pairs(dragData.racers) do
              if rRacer.lane == racerInfo.laneNum then
                racerInfo.configHash = M.generateHashFromFile(rVehId)
                break
              end
            end
          end
        end
        table.insert(dialTimes[timesKey].history, historyEntry)
      end
    end
  end

  if profilePath then return overhaul_career_saveSystem.jsonWriteFileSafe(profilePath .. "/dragDialTimes.json", dialTimes, true) end
end

--- Returns dial times keyed by config hash.
M.getDialTimes = function()
  local dialTimes = getDialData()
  local result = {}
  for configHash, data in pairs(dialTimes) do
    result[configHash] = {}
    result[configHash].time_1_4 = data.time_1_4 or 10
    for k, v in pairs(data) do
      if k ~= "history" and k ~= "time_1_4" then
        result[configHash][k] = v
      end
    end
  end
  return result
end

--- Generates a stable hash from the vehicle's config file for dial/history keys.
-- vehicleId: vehicle ID (defaults to player vehicle)
M.generateHashFromFile = function(vehicleId)
  if not vehicleId then
    vehicleId = be:getPlayerVehicleID(0)
  end
  local vehicleDetails = core_vehicles.getVehicleDetails(vehicleId)
  if not vehicleDetails or not vehicleDetails.current then
    log('W', logTag, 'Could not get vehicle details for ID: ' .. tostring(vehicleId))
    return "vehicle_" .. tostring(vehicleId)
  end
  local configFile = vehicleDetails.current.pc_file
  if not configFile or configFile == "" then
    return "vehicle_" .. tostring(vehicleId)
  end
  if not string.find(configFile, "^/") then
    configFile = "/" .. configFile
  end
  if FS:fileExists(configFile) then
    local hash = FS:hashFile(configFile)
    if hash and hash ~= "" then return hash end
  end
  return "vehicle_" .. tostring(vehicleId)
end

--- Returns current career save path, or empty string.
M.getCurrentSavePath = function()
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  return savePath or ""
end

--- Copies dial times to a save directory.
-- dir: target directory path
M.saveDialFile = function(dir)
  if not dir then return false end
  local dialTimes = getDialData()
  local savePath = dir .. "/dragDialTimes.json"
  local success = overhaul_career_saveSystem.jsonWriteFileSafe(savePath, dialTimes, true)
  if not success then
    log('E', logTag, 'Failed to save dial file to: ' .. savePath)
  end
  return success
end

--- Returns history entries from dial times. Optionally filters by drag settings id / strip file id on this level.
M.getHistory = function(id)
  local dialTimes = getDialData()
  local allHistory = {}
  for _, data in pairs(dialTimes) do
    if data.history then
      for _, entry in ipairs(data.history) do
        table.insert(allHistory, entry)
      end
    end
  end

  if not id then
    return { history = allHistory }
  end

  local levelPath = getCurrentLevelDragPath()
  local stripIdsToMatch = {}
  local seen = {}
  local function addStripId(sid)
    if sid and sid ~= "" and not seen[sid] then
      seen[sid] = true
      table.insert(stripIdsToMatch, sid)
    end
  end

  if levelPath then
    local settingsFiles = FS:findFiles(levelPath, "*.dragSettings.json", -1, true, false)
    for _, file in ipairs(settingsFiles) do
      local data = jsonReadFile(file)
      if data then
        local _, fn, ext = path.split(file, true)
        local base = string.sub(fn, 1, #fn - #ext - 1)
        local settingsId = data.id or base
        if settingsId == id or base == id then
          addStripId(settingsId)
          addStripId(base)
          if data.stripId then
            local stripData = jsonReadFile(data.stripId)
            if not stripData then
              stripData = jsonReadFile(data.stripId:gsub("/dragRaces/", "/dragstrips/"))
            end
            if not stripData then
              stripData = jsonReadFile(data.stripId:gsub("/dragstrips/", "/dragRaces/"))
            end
            if stripData and stripData.id then
              addStripId(stripData.id)
            end
          end
        end
      end
    end
  end

  if #stripIdsToMatch == 0 then
    for _, entry in ipairs(allHistory) do
      if entry.stripId and string.find(entry.stripId, "^" .. id) then
        addStripId(entry.stripId)
      end
    end
  end

  if #stripIdsToMatch == 0 then
    addStripId(id)
  end

  local filteredHistory = {}
  for _, entry in ipairs(allHistory) do
    if entry.stripId then
      for _, stripId in ipairs(stripIdsToMatch) do
        if entry.stripId == stripId then
          table.insert(filteredHistory, entry)
          break
        end
      end
    end
  end

  return { history = filteredHistory }
end

--- Hook: saves dial file when save slot changes.
-- currentSavePath: path to current save directory
M.onOverhaulSaveCurrentProfile = function(currentSavePath)
  if currentSavePath then M.saveDialFile(currentSavePath) end
end

M.onOverhaulActive = function() dialTimes = nil; profilePath = nil end
M.onOverhaulSetProfile = M.onOverhaulActive

--- Returns all strip data from current level.
M.getAllStrips = function()
  local strips = {}
  local levelPath = getCurrentLevelDragPath()
  if levelPath then
    local stripFiles = FS:findFiles(levelPath, "*.strip.json", -1, true, false)
    for _, file in ipairs(stripFiles) do
      local strip = jsonReadFile(file)
      if strip then
        strip._filePath = file
        table.insert(strips, strip)
      end
    end
  end
  return strips
end

--- Returns all lanes from all strips in current level.
M.getAllLanes = function()
  local lanes = {}
  for _, strip in ipairs(M.getAllStrips()) do
    if strip.lanes then
      for _, lane in ipairs(strip.lanes) do
        lane._stripId = strip.id
        lane._stripName = strip.name
        table.insert(lanes, lane)
      end
    end
  end
  return lanes
end

M.saveStrip = function(strip, filePath)
  if strip and strip.id and strip.lanes then
    for laneIndex, lane in ipairs(strip.lanes) do
      if lane.waypoints then
        for _, wp in ipairs(lane.waypoints) do
          if wp.type then
            wp.name = M.laneWaypointSceneName(strip.id, wp.type, laneIndex)
          end
        end
      end
    end
  end
  return jsonWriteFile(filePath, strip, true)
end
M.saveLane = function(lane, filePath) return jsonWriteFile(filePath, lane, true) end

--- Spawns prefabs from data.prefabs into the scene.
-- data: drag data with prefabs table
M.loadPrefabs = function(data)
  if not data or not data.prefabs then return end
  local prefabDefs = {
    { key = "christmasTree", nameFn = function(p) return (({[".400"] = "Pro Tree", [".500"] = "Sportsman Tree"})[p.treeType]) or "Christmas Tree" end },
    { key = "displaySign", nameFn = function() return "Display Sign" end },
    { key = "decorations", nameFn = function() return "Decorations" end },
    { key = "paths", nameFn = function() return "Paths" end },
  }
  for _, def in ipairs(prefabDefs) do
    local p = data.prefabs[def.key]
    if p and p.isUsed and p.path then
      local prefabId = spawnPrefab(def.nameFn(p), p.path, "0 0 0", "0 0 1 0", "1 1 1", false)
      if prefabId then p.prefabId = prefabId:getID() end
    end
  end
end

--- Removes prefabs from the scene and clears prefabId on data.
-- data: drag data with prefabs table
M.unloadPrefabs = function(data)
  if not data or not data.prefabs then return end
  for _, key in ipairs({"christmasTree", "displaySign", "decorations", "paths"}) do
    local p = data.prefabs[key]
    if p and p.isUsed and p.prefabId then
      local prefabObj = scenetree.findObjectById(p.prefabId)
      if prefabObj then prefabObj:delete() end
      p.prefabId = nil
    end
  end
end

-- Keep navigation registered between runs; rebuilding it at every exit stalls staging.
M.onDragClearComplete = function() end
M.onClientEndMission = M.unloadDragStripWaypoints
M.onOverhaulModeStopped = M.unloadDragStripWaypoints

-- Keep geometry calls in the owned loader only during Overhaul; stock callers recover on stop.
local geometryPatchRegistered = false
function M.onExtensionLoaded()
  if geometryPatchRegistered then return end
  local wrappers = {}
  for _, name in ipairs({"loadCompleteDragRaceData", "loadDragStripData", "convertLegacyData", "syncDragStripWaypointsWithSceneTree", "unloadPrefabs"}) do
    local method = name
    wrappers[method] = function()
      return function(...) return M[method](...) end
    end
  end
  local patches = overhaul_shell_patches
  patches.registerFields("stockDragGeometry", patches.onDemandExtension("gameplay_drag_saveSystem"), wrappers)
  geometryPatchRegistered = true
end

function M.onExtensionUnloaded()
  if geometryPatchRegistered then
    overhaul_shell_patches.unregister("stockDragGeometry")
    geometryPatchRegistered = false
  end
  M.unloadDragStripWaypoints()
end

return M
