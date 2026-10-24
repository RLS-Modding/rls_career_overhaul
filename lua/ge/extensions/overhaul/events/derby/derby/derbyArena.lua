-- Derby arena configuration, spatial objects, barriers and level refresh.
-- Read shared spatial primitives, the per-load arena operations and their returned services.
local eventConfig = require("overhaul/events/derby/config")
local catalog = require("overhaul/lib/platform/jsonCatalog")
local lib = {}

function lib.create(ownerServices)
  local freeroamUtils = ownerServices.freeroamUtils
  local constants = ownerServices.constants
  local derbyState = ownerServices.derbyState
  local _log = ownerServices._log

  local function deepMerge(defaults, overrides)
    local result = {}
    if type(defaults) == "table" then
      for k, v in pairs(defaults) do
        result[k] = v
      end
    end
    if type(overrides) == "table" then
      for k, v in pairs(overrides) do
        result[k] = v
      end
    end
    return result
  end

  -- Data loading ----------------------------------------------------------------------------------
  local function loadConfigData(logOnFailure)
    local levelId = getCurrentLevelIdentifier()
    if not levelId or levelId == "" then return nil end
    local path = "levels/" .. levelId .. "/" .. constants.CONFIG_FILENAME
    local data = jsonReadFile(path)
    if type(data) ~= "table" then
      if logOnFailure ~= false then _log("W", "Could not load " .. path) end
      return nil
    end
    derbyState.derbySitesByFile = {}
    return data
  end

  local function loadSitesData(sitesFile, logOnFailure)
    local levelId = getCurrentLevelIdentifier()
    if not levelId or levelId == "" then return nil end
    if type(sitesFile) ~= "string" or sitesFile == "" then
      if logOnFailure ~= false then _log("W", "Derby sitesFile is not configured") end
      return nil
    end
    local cache = derbyState.derbySitesByFile or {}
    derbyState.derbySitesByFile = cache
    if cache[sitesFile] then return cache[sitesFile] end
    local path = "levels/" .. levelId .. "/" .. sitesFile
    local data = jsonReadFile(path)
    if type(data) ~= "table" then
      if logOnFailure ~= false then _log("W", "Could not load " .. path) end
      return nil
    end
    cache[sitesFile] = data
    return data
  end

  -- Resolve children by id because SimGroup returns base objects without class methods.
  local function listSceneObjectChildren(obj)
    local out = {}
    if not obj or not obj.getCount then return out end
    local ok, count = pcall(function()
      return obj:getCount()
    end)
    if not ok or not count then return out end
    for i = 0, count - 1 do
      local childOk, child = pcall(function()
        return Sim.upcast(obj:getObject(i))
      end)
      if childOk and child then table.insert(out, child) end
    end
    return out
  end

  local function setDerbyArenaBarrierObjectState(obj, hidden)
    if not obj then return end
    local isHidden = hidden == true
    if obj.setHidden then pcall(function()
      obj:setHidden(isHidden)
    end) end
    if obj.setField then pcall(function()
      obj:setField("isRenderEnabled", 0, isHidden and "0" or "1")
    end) end
    if isHidden then
      if obj.disableCollision then pcall(function()
        obj:disableCollision()
      end) end
    elseif obj.enableCollision then
      pcall(function()
        obj:enableCollision()
      end)
    end
    for _, child in ipairs(listSceneObjectChildren(obj)) do
      setDerbyArenaBarrierObjectState(child, hidden)
    end
  end

  local function getDerbyArenaBarriersGroupName()
    local configured = (derbyState.activeEventCfg and derbyState.activeEventCfg.arenaBarriersGroup)
      or (derbyState.configData and derbyState.configData.arenaBarriersGroup)
    if type(configured) == "string" and configured ~= "" then return configured end
    return nil
  end

  local function isDerbyArenaBarriersPhaseActive()
    return derbyState.eventPhase == "gridStaged"
      or derbyState.eventPhase == "countdown"
      or derbyState.eventPhase == "running"
      or derbyState.eventPhase == "results"
  end

  local function setDerbyArenaBarriersVisible(visible)
    local wantVisible = visible == true
    local groupName = getDerbyArenaBarriersGroupName()
    if not groupName then
      if wantVisible then _log("W", "Derby arena barriers are not configured") end
      return false
    end
    if derbyState.derbyArenaBarriersVisible == wantVisible and derbyState.derbyArenaBarriersGroupName == groupName then
      return wantVisible
    end

    local root = scenetree.findObject(groupName)
    if not root then
      if wantVisible then _log("W", "Derby arena barriers group not found: " .. groupName) end
      return false
    end

    setDerbyArenaBarrierObjectState(root, not wantVisible)
    pcall(function()
      be:reloadCollision()
    end)
    derbyState.derbyArenaBarriersVisible = wantVisible
    derbyState.derbyArenaBarriersGroupName = groupName
    return true
  end

  local function hideDerbyArenaBarriers()
    setDerbyArenaBarriersVisible(false)
  end

  local function showDerbyArenaBarriers()
    setDerbyArenaBarriersVisible(true)
  end

  local function syncDerbyArenaBarriersVisibility()
    setDerbyArenaBarriersVisible(isDerbyArenaBarriersPhaseActive())
  end

  local function getEventConfig(eventKey)
    if not derbyState.configData or not derbyState.configData.events then return nil end
    local eventDef = derbyState.configData.events[eventKey]
    if not eventDef then return nil end
    local defaults = derbyState.configData.defaults or {}
    local config = deepMerge(defaults, eventDef)
    config.sitesFile = config.sitesFile or derbyState.configData.sitesFile
    eventConfig.normalize(config)
    return config
  end

  -- Spatial resolution from the sites file --------------------------------------------------------
  local function resolveParkingSpots(prefix)
    if not derbyState.sitesData or not derbyState.sitesData.parkingSpots then return {} end
    local spots = {}
    for _, spot in ipairs(derbyState.sitesData.parkingSpots) do
      local name = spot and spot.name or ""
      if type(name) == "string" and name:sub(1, #prefix) == prefix then table.insert(spots, spot) end
    end
    table.sort(spots, function(a, b)
      local an = tonumber((a.name or ""):match("(%d+)$")) or math.huge
      local bn = tonumber((b.name or ""):match("(%d+)$")) or math.huge
      return an < bn
    end)
    return spots
  end

  local function resolveZone(zoneName)
    if not derbyState.sitesData or not derbyState.sitesData.zones then return nil end
    for _, zone in ipairs(derbyState.sitesData.zones) do
      if zone and zone.name == zoneName then return zone end
    end
    return nil
  end

  local function validPlayZone(zone)
    if not zone or type(zone.vertices) ~= "table" or #zone.vertices < 3 then return false end
    for _, vertex in ipairs(zone.vertices) do
      if type(vertex) ~= "table" then return false end
      for index = 1, 3 do
        if not catalog.finite(vertex[index]) then return false end
      end
    end
    return true
  end

  -- A projection must not replace the running event's sites or resolved spatial objects.
  local function getEventLocation(eventKey)
    local config = getEventConfig(eventKey)
    if not config then return nil end
    local sites = loadSitesData(config.sitesFile, false)
    for _, zone in ipairs(sites and sites.zones or {}) do
      if zone.name == config.playZone and validPlayZone(zone) then return config, sites end
    end
    _log("W", "Derby event unavailable: invalid playZone or sitesFile for " .. tostring(eventKey))
    return nil
  end

  local function getAvailableEventKeys()
    if not derbyState.configData or not derbyState.configData.events then return {} end
    local keys = {}
    for key in pairs(derbyState.configData.events) do
      if getEventLocation(key) then table.insert(keys, key) end
    end
    table.sort(keys)
    return keys
  end

  local function refreshDerbyForCurrentLevel()
    local levelId = getCurrentLevelIdentifier()
    if levelId == "" then levelId = nil end
    if derbyState.derbyLevelId == levelId and derbyState.derbyLevelReady then return derbyState.derbyAvailable end
    if not levelId then
      derbyState.derbyLevelId = nil
      derbyState.derbyLevelReady = true
      derbyState.derbyAvailable = false
      derbyState.configData = nil
      derbyState.sitesData = nil
      derbyState.derbySitesByFile = nil
      hideDerbyArenaBarriers()
      return false
    end

    derbyState.derbyLevelId = levelId
    derbyState.derbyLevelReady = true
    derbyState.derbyArenaBarriersVisible = nil
    derbyState.derbySitesByFile = {}
    derbyState.configData = loadConfigData(false)
    if not derbyState.configData then
      derbyState.derbyAvailable = false
      derbyState.sitesData = nil
      hideDerbyArenaBarriers()
      return false
    end

    derbyState.sitesData = loadSitesData(derbyState.configData.sitesFile, false)
    derbyState.derbyAvailable = #getAvailableEventKeys() > 0
    syncDerbyArenaBarriersVisibility()
    return derbyState.derbyAvailable
  end

  local function resolveParkingSpotByName(spotName, eventKey)
    if type(spotName) ~= "string" or spotName == "" then return nil end
    local sites = derbyState.sitesData
    if eventKey then
      local config
      config, sites = getEventLocation(eventKey)
      if not config then return nil end
    end
    for _, spot in ipairs(sites and sites.parkingSpots or {}) do
      if spot and spot.name == spotName then return spot end
    end
    return nil
  end

  local function resolveZones(zoneNames)
    if type(zoneNames) ~= "table" then return {} end
    local zones = {}
    for _, name in ipairs(zoneNames) do
      local zone = resolveZone(name)
      if zone then
        table.insert(zones, zone)
      else
        _log("W", "Zone not found in sites file: " .. tostring(name))
      end
    end
    return zones
  end

  -- Resolve all spatial data for a given event config
  local function resolveAllSpatialData(cfg)
    if not cfg then return false end
    derbyState.sitesData = loadSitesData(cfg.sitesFile)
    if not derbyState.sitesData then return false end
    local prefix = cfg.spawnPrefix
    if type(prefix) ~= "string" or prefix == "" then
      _log("W", "Derby event unavailable: spawnPrefix is not configured")
      return false
    end
    derbyState.resolvedSpots = resolveParkingSpots(prefix)
    derbyState.resolvedPlayZone = resolveZone(cfg.playZone)
    if not validPlayZone(derbyState.resolvedPlayZone) then
      derbyState.resolvedPlayZone = nil
      _log("W", "Derby event unavailable: invalid playZone " .. tostring(cfg.playZone))
      return false
    end
    derbyState.resolvedElimZones = resolveZones(cfg.eliminationZones or {})
    return true
  end

  local function clearSpatialData()
    derbyState.resolvedSpots = nil
    derbyState.resolvedPlayZone = nil
    derbyState.resolvedElimZones = nil
  end

  local function restoreTrafficAfterEvent()
    if not derbyState.trafficSuppressedForEvent then return end

    if freeroamUtils and freeroamUtils.restoreTrafficAmount then freeroamUtils.restoreTrafficAmount() end

    derbyState.trafficSuppressedForEvent = false
  end

  -- Polygon point-in-zone test (2D, ignores Z) ----------------------------------------------------
  local function isPointInPolygon2D(px, py, vertices)
    if not vertices or #vertices < 3 then return false end
    local inside = false
    local n = #vertices
    local j = n
    for i = 1, n do
      local xi, yi = vertices[i][1], vertices[i][2]
      local xj, yj = vertices[j][1], vertices[j][2]
      if ((yi > py) ~= (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then inside = not inside end
      j = i
    end
    return inside
  end

  local function isInsideZone(pos, zone)
    if not zone or not zone.vertices or #zone.vertices < 3 then return false end
    return isPointInPolygon2D(pos.x, pos.y, zone.vertices)
  end

  local function isInsideAnyEliminationZone(pos)
    if not derbyState.resolvedElimZones then return false end
    for _, zone in ipairs(derbyState.resolvedElimZones) do
      if isInsideZone(pos, zone) then return true end
    end
    return false
  end

  local function isInsidePlayZone(pos)
    if not validPlayZone(derbyState.resolvedPlayZone) then return false end
    return isInsideZone(pos, derbyState.resolvedPlayZone)
  end

  local function getPlayzoneCentroid()
    if
      not derbyState.resolvedPlayZone
      or not derbyState.resolvedPlayZone.vertices
      or #derbyState.resolvedPlayZone.vertices < 3
    then
      return nil
    end
    local sumX, sumY, sumZ = 0, 0, 0
    for _, v in ipairs(derbyState.resolvedPlayZone.vertices) do
      sumX = sumX + v[1]
      sumY = sumY + v[2]
      sumZ = sumZ + v[3]
    end
    local count = #derbyState.resolvedPlayZone.vertices
    return vec3(sumX / count, sumY / count, sumZ / count)
  end

  local function distanceToLineSegment2D(px, py, x1, y1, x2, y2)
    local l2 = (x1 - x2) ^ 2 + (y1 - y2) ^ 2
    if l2 == 0 then return math.sqrt((px - x1) ^ 2 + (py - y1) ^ 2) end
    local t = math.max(0, math.min(1, ((px - x1) * (x2 - x1) + (py - y1) * (y2 - y1)) / l2))
    local projX = x1 + t * (x2 - x1)
    local projY = y1 + t * (y2 - y1)
    return math.sqrt((px - projX) ^ 2 + (py - projY) ^ 2)
  end

  local function getDistanceToPlayZoneEdge(pos)
    if not derbyState.resolvedPlayZone or not derbyState.resolvedPlayZone.vertices then return math.huge end
    local minD = math.huge
    local n = #derbyState.resolvedPlayZone.vertices
    local j = n
    for i = 1, n do
      local d = distanceToLineSegment2D(
        pos.x,
        pos.y,
        derbyState.resolvedPlayZone.vertices[i][1],
        derbyState.resolvedPlayZone.vertices[i][2],
        derbyState.resolvedPlayZone.vertices[j][1],
        derbyState.resolvedPlayZone.vertices[j][2]
      )
      if d < minD then minD = d end
      j = i
    end
    return minD
  end

  local function getPlayZoneBounds2D()
    if
      not derbyState.resolvedPlayZone
      or not derbyState.resolvedPlayZone.vertices
      or #derbyState.resolvedPlayZone.vertices < 3
    then
      return nil
    end

    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    for _, v in ipairs(derbyState.resolvedPlayZone.vertices) do
      minX = math.min(minX, v[1])
      maxX = math.max(maxX, v[1])
      minY = math.min(minY, v[2])
      maxY = math.max(maxY, v[2])
    end

    if minX == math.huge or minY == math.huge then return nil end

    return minX, maxX, minY, maxY
  end

  return {
    loadConfigData = loadConfigData,
    loadSitesData = loadSitesData,
    hideDerbyArenaBarriers = hideDerbyArenaBarriers,
    showDerbyArenaBarriers = showDerbyArenaBarriers,
    refreshDerbyForCurrentLevel = refreshDerbyForCurrentLevel,
    getEventConfig = getEventConfig,
    getEventLocation = getEventLocation,
    getAvailableEventKeys = getAvailableEventKeys,
    resolveParkingSpotByName = resolveParkingSpotByName,
    resolveAllSpatialData = resolveAllSpatialData,
    clearSpatialData = clearSpatialData,
    restoreTrafficAfterEvent = restoreTrafficAfterEvent,
    isInsideAnyEliminationZone = isInsideAnyEliminationZone,
    isInsidePlayZone = isInsidePlayZone,
    getPlayzoneCentroid = getPlayzoneCentroid,
    getDistanceToPlayZoneEdge = getDistanceToPlayZoneEdge,
    getPlayZoneBounds2D = getPlayZoneBounds2D,
  }
end

return lib
