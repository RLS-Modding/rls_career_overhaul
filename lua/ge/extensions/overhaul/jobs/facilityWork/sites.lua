-- Facility site lookup, spawn zones and forklift positions.
-- The owner supplies live facility data when configuration reloads.
return function(facilityConfigs, getZoneCenter, loadConfig, toVec3, validZoneVertices)
  local levelData = require('overhaul/lib/world/levelData')
  local sitesCache = {}

  local function validateSites(raw, path)
    for _, key in ipairs({"parkingSpots", "zones"}) do
      if raw[key] ~= nil and type(raw[key]) ~= "table" then
        log("W", "facilityWork", "Facility disabled: invalid " .. key .. " collection in " .. path)
        return false
      end
    end
    for index = #(raw.parkingSpots or {}), 1, -1 do
      local spot = raw.parkingSpots[index]
      local pos = type(spot) == "table" and (spot.pos or (spot.vertices and spot.vertices[1]))
      if not toVec3(pos) then
        log("W", "facilityWork", "Ignoring forklift spot " .. tostring(type(spot) == "table" and spot.name or index) .. ": position requires 3 finite numbers in " .. path)
        table.remove(raw.parkingSpots, index)
      end
    end
    for index = #(raw.zones or {}), 1, -1 do
      local zone = raw.zones[index]
      if type(zone) ~= "table" or not validZoneVertices(zone.vertices) then
        log("W", "facilityWork", "Ignoring facility zone " .. tostring(type(zone) == "table" and zone.name or index) .. ": requires at least 3 vertices with 3 finite coordinates in " .. path)
        table.remove(raw.zones, index)
      end
    end
    return raw
  end

  local function getSitesRaw(cfg)
    local level = getCurrentLevelIdentifier()
    if not level or not cfg or not cfg.sitesFile then return nil end
    local path = levelData.assetPath(level, cfg.sitesFile)
    if sitesCache[path] == nil then
      local raw = jsonReadFile(path)
      sitesCache[path] = type(raw) == "table" and validateSites(raw, path) or false
      if not sitesCache[path] then log("W", "facilityWork", "Facility disabled: missing sites " .. path) end
    end
    return sitesCache[path] or nil
  end

  local function getForkliftSpawnPoint(spotName, cfg)
    local targetName = spotName
    if not targetName then return nil end
    local raw = getSitesRaw(cfg)
    if raw and raw.parkingSpots then
      for _, spot in ipairs(raw.parkingSpots) do
        local name = spot.name or (spot.objects and spot.objects[1] and spot.objects[1].name)
        if name == targetName then
          local pos = spot.pos or (spot.vertices and spot.vertices[1])
          local rot = spot.rot or spot.rotation
          if pos then
            return { pos = toVec3(pos), rot = rot and quat(rot) or quat(0,0,0,1) }
          end
        end
      end
    end
    return nil
  end

  local function getSpawnZoneVertices(zoneName, cfg)
    local targetName = zoneName
    local raw = getSitesRaw(cfg)
    local zones = raw and raw.zones or nil
    if not zones or #zones == 0 then return nil end
    for _, z in ipairs(zones) do
      local name = z.name or (z.objects and z.objects[1] and z.objects[1].name)
      if name == targetName and z.vertices and #z.vertices >= 3 then
        return z.vertices
      end
    end
    return nil
  end

  local function getFacilitySpawnZoneNames(cfg)
    if not cfg then return {} end
    if cfg.spawnZones and type(cfg.spawnZones) == "table" and #cfg.spawnZones > 0 then
      return cfg.spawnZones
    end
    local single = cfg.spawnZone
    return single and { single } or {}
  end

  local function getFacilityLoadZoneVertices(facilityId)
    if not facilityId then return nil end
    local cfg = facilityConfigs[facilityId]
    if not cfg then return nil end
    local names = getFacilitySpawnZoneNames(cfg)
    for _, name in ipairs(names) do
      local verts = getSpawnZoneVertices(name, cfg)
      if verts then return verts end
    end
    return nil
  end

  local function getFacilityLoadZoneCenter(facilityId)
    return getZoneCenter(getFacilityLoadZoneVertices(facilityId))
  end

  local function facilityAvailable(cfg)
    if not getForkliftSpawnPoint(cfg.forkliftSpawnSpot or cfg.parkingSpot, cfg) then return false end
    for _, zoneName in ipairs(getFacilitySpawnZoneNames(cfg)) do
      if getSpawnZoneVertices(zoneName, cfg) then return true end
    end
    return false
  end

  local function isFacilityWorkAvailable()
    if not loadConfig() then return false end
    for _, cfg in pairs(facilityConfigs) do
      if facilityAvailable(cfg) then return true end
    end
    return false
  end

  local function getAvailableFacilities()
    if not loadConfig() then return {} end
    local list = {}
    for id, cfg in pairs(facilityConfigs) do
      if facilityAvailable(cfg) then table.insert(list, {
        id = id,
        name = cfg.name or id,
        batchSize = cfg.batchSize or 8
      }) end
    end
    return list
  end

  return {getAvailableFacilities = getAvailableFacilities,
    getFacilityLoadZoneCenter = getFacilityLoadZoneCenter,
    getFacilitySpawnZoneNames = getFacilitySpawnZoneNames,
    getForkliftSpawnPoint = getForkliftSpawnPoint, getSpawnZoneVertices = getSpawnZoneVertices,
    isFacilityWorkAvailable = isFacilityWorkAvailable,
    set_facilityConfigs = function(value) facilityConfigs = value; sitesCache = {} end}

end
