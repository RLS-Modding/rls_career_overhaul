local M = {}

local Config = gameplay_loading_config

M.sitesData = nil
M.sitesFilePath = nil
M.availableGroups = {}
M.groupCache = {}
M.stockRegenTimer = 0
M.groupCachePrecomputeQueued = false
M.sitesLoadTimer = 0
M.materialZoneMap = {}

local function findOffRoadCentroid(zone, minRoadDist, maxPoints)
  if not zone or not zone.aabb or zone.aabb.invalid then return nil end
  if not map or not map.findClosestRoad then return nil end

  minRoadDist = minRoadDist or 5
  maxPoints = maxPoints or 1000

  local xMin, xMax = zone.aabb.xMin, zone.aabb.xMax
  local yMin, yMax = zone.aabb.yMin, zone.aabb.yMax
  local xRange, yRange = math.max(0.1, xMax - xMin), math.max(0.1, yMax - yMin)

  local step = math.max(2, math.sqrt((xRange * yRange) / maxPoints))

  local sum = vec3(0,0,0)
  local count = 0

  local x = xMin
  while x <= xMax do
    local y = yMin
    while y <= yMax do
      local p = vec3(x, y, 0)
      p.z = core_terrain.getTerrainHeight(p)
      if zone:containsPoint2D(p) then
        local _, _, dist = map.findClosestRoad(p)
        if dist and dist > minRoadDist then
          sum = sum + p
          count = count + 1
        end
      end
      y = y + step
    end
    x = x + step
  end

  if count == 0 then return nil end
  local centroid = sum / count
  centroid.z = core_terrain.getTerrainHeight(centroid)
  return centroid
end

local function ensureGroupCache(group, getCurrentGameHour)
  if not group or not group.secondaryTag then return nil end
  local key = tostring(group.secondaryTag)
  local cache = M.groupCache[key]
  if cache then
    if cache.materialStocks then
      local getSimTime = nil
      if extensions.gameplay_loading_contracts and extensions.gameplay_loading_contracts.getSimTime then
        getSimTime = extensions.gameplay_loading_contracts.getSimTime
      end
      local currentSimTime = getSimTime and getSimTime() or 0
      for matKey, stock in pairs(cache.materialStocks) do
        if stock.nextRegenTime and not stock.nextRegenSimTime then
          local regenRate = stock.regenRate or 0
          if regenRate > 0 then
            stock.nextRegenSimTime = currentSimTime + (3600 / regenRate)
            stock.nextRegenTime = nil
          end
        end
      end
    end
    return cache
  end

  -- Strict check: Find this site in the loaded facilities JSON
  local siteConfig = nil
  local facilities = extensions.gameplay_loading_config.facilities
  if facilities then
    for _, facility in pairs(facilities) do
      if facility.sites and facility.sites[key] then
        siteConfig = facility.sites[key]
        break
      end
    end
  end

  -- No JSON config = No stock logic for this zone
  if not siteConfig then
    return nil
  end

  local materials = siteConfig.materials or {}
  
  if not materials or next(materials) == nil then
    return nil
  end

  local materialStocks = {}
  local getSimTime = nil
  if extensions.gameplay_loading_contracts and extensions.gameplay_loading_contracts.getSimTime then
    getSimTime = extensions.gameplay_loading_contracts.getSimTime
  end
  local currentSimTime = getSimTime and getSimTime() or 0
  for matKey, matData in pairs(materials) do
    local matConfig = Config and Config.materials and Config.materials[matKey]
    local isMass = matConfig and matConfig.unitType == "mass"
    local maxStock = matData.maxStock or 0
    local startStock = matData.startStock or maxStock
    if isMass then
      maxStock = maxStock * 1000
      startStock = startStock * 1000
    end
    local regenRate = matData.regenRate or 0
    local nextRegenSimTime = nil
    if regenRate > 0 then
      nextRegenSimTime = currentSimTime + (3600 / regenRate)
    end
    materialStocks[matKey] = {
      current = startStock,
      max = maxStock,
      regenRate = regenRate,
      nextRegenSimTime = nextRegenSimTime,
    }
  end

  cache = {
    materialStocks = materialStocks,
    spawnedPropCounts = {},
    name = siteConfig.name or key,
  }
  M.groupCache[key] = cache
  
  return cache
end

local function ensureGroupOffRoadCentroid(group, getCurrentGameHour)
  local cache = ensureGroupCache(group, getCurrentGameHour)
  if not cache then return nil end
  if group and group.loading and not cache.offRoadCentroid then
    cache.offRoadCentroid = findOffRoadCentroid(group.loading, 5, 1000)
  end
  return cache
end

local function updateZoneStocks(dt, getSimTime)
  if not getSimTime then return end
  local currentSimTime = getSimTime()

  for _, group in ipairs(M.availableGroups) do
    local cache = M.groupCache[tostring(group.secondaryTag)]
    if cache and cache.materialStocks then
      for matKey, stock in pairs(cache.materialStocks) do
        if stock.nextRegenTime and not stock.nextRegenSimTime then
          local regenRate = stock.regenRate or 0
          if regenRate > 0 then
            stock.nextRegenSimTime = currentSimTime + (3600 / regenRate)
            stock.nextRegenTime = nil
          end
        end
        
        if stock.nextRegenSimTime and stock.regenRate > 0 then
          local secondsUntilRegen = stock.nextRegenSimTime - currentSimTime
          
          if secondsUntilRegen <= 0 then
            if stock.current < stock.max then
              local oldStock = stock.current
              local matConfig = Config and Config.materials and Config.materials[matKey]
              local isMass = matConfig and matConfig.unitType == "mass"
              local regenAmount = isMass and 1000 or 1
              stock.current = math.min(stock.max, stock.current + regenAmount)
              stock.nextRegenSimTime = currentSimTime + (3600 / stock.regenRate)
            else
              stock.nextRegenSimTime = currentSimTime + (3600 / stock.regenRate)
            end
          end
        end
      end
    end
  end
end

local function getZoneStockInfo(group, getCurrentGameHour)
  if not group then return nil end
  local cache = ensureGroupCache(group, getCurrentGameHour)
  if not cache or not cache.materialStocks then return nil end
  
  local totalCurrent = 0
  local totalMax = 0
  for _, stock in pairs(cache.materialStocks) do
    totalCurrent = totalCurrent + stock.current
    totalMax = totalMax + stock.max
  end
  
  return {
    current = math.floor(totalCurrent + 0.5),
    max = math.floor(totalMax + 0.5),
    materialStocks = cache.materialStocks,
    spawnedProps = cache.spawnedPropCounts or {},
    materials = group.materials or (group.materialType and {group.materialType} or {})
  }
end

local function discoverGroups(sites)
  local groups = {}
  if not sites or not sites.sortedTags then return groups end

  local primary = { spawn = true, destination = true, loading = true }
  local materialTags = {}
  if Config.materials then
    for k, _ in pairs(Config.materials) do materialTags[k] = true end
  end

  for _, secondaryTag in ipairs(sites.sortedTags) do
    if not primary[secondaryTag] and not materialTags[secondaryTag] then
      local spawnLoc, destLoc, loadingZone
      local sCount, dCount, zCount = 0, 0, 0

      for _, loc in ipairs(sites.tagsToLocations.spawn or {}) do
        if loc.customFields and loc.customFields.tags and loc.customFields.tags[secondaryTag] then
          sCount = sCount + 1
          spawnLoc = loc
        end
      end
      for _, loc in ipairs(sites.tagsToLocations.destination or {}) do
        if loc.customFields and loc.customFields.tags and loc.customFields.tags[secondaryTag] then
          dCount = dCount + 1
          destLoc = loc
        end
      end
      for _, zone in ipairs(sites.tagsToZones.loading or {}) do
        if zone.customFields and zone.customFields.tags and zone.customFields.tags[secondaryTag] then
          zCount = zCount + 1
          loadingZone = zone
        end
      end

      if sCount == 1 and dCount == 1 and zCount == 1 then
        local materials = {}
        local materialType = nil
        local associatedOrg = nil
        
        local facilities = Config.facilities
        if facilities then
          for _, facility in pairs(facilities) do
            if facility.sites and facility.sites[secondaryTag] then
              local siteConfig = facility.sites[secondaryTag]
              local siteMaterials = siteConfig.materials or {}
              for matKey, _ in pairs(siteMaterials) do
                if Config.materials[matKey] then
                  table.insert(materials, matKey)
                  if not materialType then
                    materialType = matKey
                  end
                end
              end
              if facility.associatedOrganization then
                associatedOrg = facility.associatedOrganization
              end
              break
            end
          end
        end
        
        if #materials == 0 and loadingZone.customFields and loadingZone.customFields.tags then
          for tag, _ in pairs(loadingZone.customFields.tags) do
            if materialTags[tag] then
              table.insert(materials, tag)
              if not materialType then
                materialType = tag
              end
            end
          end
        end
        
        if #materials > 0 then
          local materialSpawnLocations = {}
          local stopLocations = {}
          local addedMaterialIds = {}
          
          for _, loc in ipairs(sites.tagsToLocations.spawn or {}) do
            if loc.customFields and loc.customFields.tags and loc.customFields.tags[secondaryTag] then
              if loc.customFields.tags.material then
                if not addedMaterialIds[loc.id] then
                  table.insert(materialSpawnLocations, loc)
                  addedMaterialIds[loc.id] = true
                end
              end
            end
          end
          
          for _, loc in ipairs(sites.tagsToLocations.stop or {}) do
            if loc.customFields and loc.customFields.tags and loc.customFields.tags[secondaryTag] then
              table.insert(stopLocations, loc)
            end
          end
          
          for _, loc in ipairs(sites.tagsToLocations.material or {}) do
            if loc.customFields and loc.customFields.tags and loc.customFields.tags[secondaryTag] then
              if not loc.customFields.tags.stop then
                if not addedMaterialIds[loc.id] then
                  table.insert(materialSpawnLocations, loc)
                  addedMaterialIds[loc.id] = true
                end
              end
            end
          end
          
          table.insert(groups, {
            secondaryTag = secondaryTag,
            spawn = spawnLoc,
            destination = destLoc,
            loading = loadingZone,
            materials = materials,
            materialType = materialType,
            associatedOrganization = associatedOrg,
            materialSpawnLocations = materialSpawnLocations,
            stopLocations = stopLocations
          })
          
        end
      end
    end
  end

  table.sort(groups, function(a, b) return tostring(a.secondaryTag) < tostring(b.secondaryTag) end)
  return groups
end

local function buildMaterialZoneMap()
  M.materialZoneMap = {}
  for _, g in ipairs(M.availableGroups) do
    if g.materials then
      for _, matKey in ipairs(g.materials) do
        if not M.materialZoneMap[matKey] then
          M.materialZoneMap[matKey] = {}
        end
        table.insert(M.materialZoneMap[matKey], g)
      end
    elseif g.materialType then
      if not M.materialZoneMap[g.materialType] then
        M.materialZoneMap[g.materialType] = {}
      end
      table.insert(M.materialZoneMap[g.materialType], g)
    end
  end
end

local function getZonesByMaterial(materialType)
  if M.materialZoneMap[materialType] then
    return M.materialZoneMap[materialType]
  end
  local zones = {}
  for _, g in ipairs(M.availableGroups) do
    if g.materials then
      for _, matKey in ipairs(g.materials) do
        if matKey == materialType then
          table.insert(zones, g)
          break
        end
      end
    elseif g.materialType == materialType then
      table.insert(zones, g)
    end
  end
  M.materialZoneMap[materialType] = zones
  return zones
end

local function getZonesByTypeName(typeName)
  local zones = {}
  if not Config or not Config.materials then return zones end
  
  for _, g in ipairs(M.availableGroups) do
    if g.materials then
      for _, matKey in ipairs(g.materials) do
        local matConfig = Config.materials[matKey]
        if matConfig and matConfig.typeName == typeName then
          table.insert(zones, g)
          break
        end
      end
    elseif g.materialType then
      local matConfig = Config.materials[g.materialType]
      if matConfig and matConfig.typeName == typeName then
        table.insert(zones, g)
      end
    end
  end
  return zones
end

local function loadQuarrySites(getCurrentGameHour)
  local lvl = getCurrentLevelIdentifier()
  if not lvl then return end

  if M.sitesData and M.sitesFilePath then return end
  if not gameplay_sites_sitesManager then return end

  local fp = gameplay_sites_sitesManager.getCurrentLevelSitesFileByName("quarry")
  if not fp then
    for _, f in ipairs(gameplay_sites_sitesManager.getCurrentLevelSitesFiles() or {}) do
      if string.find(string.lower(f), "quarry") then
        fp = f
        break
      end
    end
  end

  if not fp then return end

  local loaded = gameplay_sites_sitesManager.loadSites(fp)
  if not loaded then return end

  M.sitesData = loaded
  M.sitesFilePath = fp
  M.availableGroups = discoverGroups(M.sitesData)
  
  buildMaterialZoneMap()

  if not M.groupCachePrecomputeQueued and #M.availableGroups > 0 then
    M.groupCachePrecomputeQueued = true
    core_jobsystem.create(function(job)
      for _, g in ipairs(M.availableGroups) do
        ensureGroupOffRoadCentroid(g, getCurrentGameHour)
        job.sleep(0.01)
      end
    end)
  end
end

local function isPlayerInAnyLoadingZone(playerPos)
  for _, g in ipairs(M.availableGroups) do
    if g.loading and g.loading.containsPoint2D and g.loading:containsPoint2D(playerPos) then
      return true
    end
  end
  return false
end

local function getPlayerCurrentZone(playerPos)
  for _, g in ipairs(M.availableGroups) do
    if g.loading and g.loading.containsPoint2D and g.loading:containsPoint2D(playerPos) then
      return g
    end
  end
  return nil
end

local function getNearestZoneWithinDistance(playerPos, maxDistance)
  if not playerPos then return nil end
  maxDistance = maxDistance or 500
  
  local nearestZone = nil
  local nearestDist = math.huge
  
  for _, g in ipairs(M.availableGroups) do
    if g.loading and g.loading.aabb and not g.loading.aabb.invalid then
      local aabb = g.loading.aabb
      local zoneCenter = vec3(
        (aabb.xMin + aabb.xMax) / 2,
        (aabb.yMin + aabb.yMax) / 2,
        0
      )
      zoneCenter.z = core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(zoneCenter) or 0
      
      local dist = (playerPos - zoneCenter):length()
      if dist <= maxDistance and dist < nearestDist then
        nearestDist = dist
        nearestZone = g
      end
    end
  end
  
  return nearestZone
end

local function getAllZonesStockInfo(getCurrentGameHour)
  local zonesStock = {}
  for _, group in ipairs(M.availableGroups) do
    local cache = ensureGroupCache(group, getCurrentGameHour)
    if cache and cache.materialStocks then
      local zoneStock = {
        zoneName = cache.name or group.secondaryTag or "Unknown",
        materials = {}
      }
      for matKey, stock in pairs(cache.materialStocks) do
        local matConfig = Config and Config.materials and Config.materials[matKey]
        local isMass = matConfig and matConfig.unitType == "mass"
        table.insert(zoneStock.materials, {
          materialKey = matKey,
          materialName = matConfig and matConfig.name or matKey,
          typeName = matConfig and matConfig.typeName or nil,
          current = isMass and math.floor((stock.current / 1000) + 0.5) or math.floor(stock.current + 0.5),
          max = isMass and math.floor((stock.max / 1000) + 0.5) or math.floor(stock.max + 0.5),
          regenRate = stock.regenRate
        })
      end
      table.insert(zonesStock, zoneStock)
    end
  end
  return zonesStock
end

local function getFacilityIdForZone(zoneTag)
  if not zoneTag then return nil end
  local facilities = Config and Config.facilities
  if not facilities then return nil end
  
  for facilityKey, facility in pairs(facilities) do
    if facility.sites and facility.sites[zoneTag] then
      return facility.id or facilityKey
    end
  end
  
  return nil
end

local function validateZoneBelongsToFacility(zoneTag, facilityId)
  if not zoneTag or not facilityId then return false end
  local facilities = Config and Config.facilities
  if not facilities then return false end
  
  local facility = facilities[facilityId]
  if not facility or not facility.sites then return false end
  
  return facility.sites[zoneTag] ~= nil
end

M.findOffRoadCentroid = findOffRoadCentroid
M.ensureGroupCache = ensureGroupCache
M.ensureGroupOffRoadCentroid = ensureGroupOffRoadCentroid
M.updateZoneStocks = updateZoneStocks
M.getZoneStockInfo = getZoneStockInfo
M.getAllZonesStockInfo = getAllZonesStockInfo
M.loadQuarrySites = loadQuarrySites
M.isPlayerInAnyLoadingZone = isPlayerInAnyLoadingZone
M.getPlayerCurrentZone = getPlayerCurrentZone
M.getNearestZoneWithinDistance = getNearestZoneWithinDistance
M.getZonesByMaterial = getZonesByMaterial
M.getZonesByTypeName = getZonesByTypeName
M.getFacilityIdForZone = getFacilityIdForZone
M.validateZoneBelongsToFacility = validateZoneBelongsToFacility
M.onExtensionLoaded = function()
end
M.loadingConfigLoaded = function()
  Config = gameplay_loading_config
end

return M




