-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/freeroam/facilities.lua (BeamNG 0.40).

-- Overhaul's facility service; the game's facility POI and prompt hooks pause while Overhaul runs.
-- Map: loading and parsing facility files, lookups, POI formatters and prompts, then the hooks and public API.

local M = {}

M.dependencies = {"overhaul_shell_patches"}

local PATCH_ID = "facilities"
local missingPreview = "/ui/images/noPreview.jpg"

local facilitiesByLevel = {}
local facilitiesLoadHadLevelInfo = {}

local facilityTypeToListName, facilityTypeToUiLabelSingular =
  require('overhaul/world/facilities/typeCatalog').maps()


-- helper function for checking if files exist
local function fileExistsDefault(path, fallbackPath)
  if path == nil then return fallbackPath end
  if type(path) ~= "table" then path = {path} end
  for _, p in ipairs(path) do
    if FS:fileExists(p) then return p end
  end
  return fallbackPath
end

-- Previews that are only a filename live under /facilities/images/.
-- Paths with their own folder (e.g. previews/ next to the json) stay relative to fileDir.
local function resolveFacilityPreview(raw, fileDir, levelDir, facilitiesBaseDir)
  if not raw or raw == '' then return raw end
  if raw:sub(1, 1) == '/' then
    return fileExistsDefault({raw}, missingPreview)
  end
  local candidates = {}
  local sharedName = nil
  if not raw:find("/", 1, true) then
    sharedName = raw
  end
  if sharedName then
    table.insert(candidates, facilitiesBaseDir .. "images/" .. sharedName)
  end
  if raw:sub(1, 7) == "images/" then
    table.insert(candidates, facilitiesBaseDir .. raw)
  end
  table.insert(candidates, fileDir .. raw)
  table.insert(candidates, levelDir .. raw)
  return fileExistsDefault(candidates, missingPreview)
end


-- parses and sanitizes a singular facility entry and adds it to the facilitiesTypeList.
local function parseFacility(f, facilityType, facilitiesTypeList, levelDir, fileDir, fileName, index, facilitiesBaseDir)
  -- sanitize
  f.id = f.id or (string.format("%s%s-%s-%d",fileDir, fileName, facilityType, index))
  f.type = facilityType
  f.preview = f.preview or 'defaultFacility.jpg'
  f.preview = resolveFacilityPreview(f.preview, fileDir, levelDir, facilitiesBaseDir)
  f.sitesFile = f.sitesFile or "facilities.sites.json"
  if type(f.sitesFile) == "table" then
    for index, file in ipairs(f.sitesFile) do
      f.sitesFile[index] = fileExistsDefault({fileDir..file, levelDir.. file}, levelDir.."facilities.sites.json")
    end
  else
    f.sitesFile = fileExistsDefault({fileDir..f.sitesFile, levelDir.. f.sitesFile}, levelDir.."facilities.sites.json")
  end

  f.zoneNames = f.zoneNames or {}
  f.parkingSpotNames = f.parkingSpotNames or {}
  table.insert(facilitiesTypeList, f)
end

-- this funcion can parse *.facilities.json, but also the info.json in a level folder.
local function parseFacilitiyFile(file, facilities, levelDir, facilitiesBaseDir)
  if not FS:fileExists(file) then return end
  local fileDir, fn, _ = path.split(file, true)
  local data = jsonReadFile(file)
  if type(data) ~= "table" then log("E", "", "Could not read facilities file: " .. tostring(file)) return end
  for type, listKey in pairs(facilityTypeToListName) do
    for i, f in ipairs(data[listKey] or {}) do
      parseFacility(f, type, facilities[listKey], levelDir, fileDir, fn, i, facilitiesBaseDir)
    end
  end
end

local function facilitiesCacheIsEmpty(facilities)
  if not facilities then return true end
  for _, listKey in pairs(facilityTypeToListName) do
    local list = facilities[listKey]
    if type(list) == "table" and list[1] then return false end
  end
  return true
end

local function getFacilities(levelName)
  if not levelName or levelName == '' then
    log("E","","Tried to get facilities without level!")
    return
  end
  local cached = facilitiesByLevel[levelName]
  if cached then
    if facilitiesLoadHadLevelInfo[levelName] or not facilitiesCacheIsEmpty(cached) then
      return cached
    end
    facilitiesByLevel[levelName] = nil
  end

  -- init facility table
  facilitiesByLevel[levelName] = {}
  for _, listKey in pairs(facilityTypeToListName) do facilitiesByLevel[levelName][listKey] = {} end

  -- parse info.json of the level
  local levelInfo = core_levels.getLevelByName(levelName)
  facilitiesLoadHadLevelInfo[levelName] = levelInfo ~= nil
  if levelInfo then
    local facilitiesBaseDir = levelInfo.dir .. "/facilities/"
    parseFacilitiyFile(levelInfo.dir.."/info.json", facilitiesByLevel[levelName], levelInfo.misFilePath, facilitiesBaseDir)

    -- parse any other facility files inside the levels /facilities folder
    for _,file in ipairs(FS:findFiles(levelInfo.dir.."/facilities/", '*.facilities.json', -1, false, true)) do
      parseFacilitiyFile(file, facilitiesByLevel[levelName], levelInfo.misFilePath, facilitiesBaseDir)
    end
  end
  log("D","",string.format("Loaded facilities on level %s (%d garages, %d gasStations, %d dealerships)",levelName, #(facilitiesByLevel[levelName].garages or {}), #(facilitiesByLevel[levelName].gasStations or {}), #(facilitiesByLevel[levelName].dealerships or {})))
  return facilitiesByLevel[levelName]
end

-- returns a single facility element. quiet=true skips the missing-id error
-- (owned garages from other career maps are valid and common).
local function getFacility(type, id, quiet)
  local levelName = getCurrentLevelIdentifier()
  if not levelName or levelName == '' then log("E","","Tried to get facility without level!") return end

  local facilities = getFacilities(levelName)
  local listName = facilityTypeToListName[type] or "none"
  if listName == "none" then log("E","","Tried to get facility of type " .. dumps(type)..", which is not a valid type! ("..dumps(tableKeysSorted(facilityTypeToListName))) end

  for _, f in ipairs(facilities[listName] or {}) do
    if f.id == id then
      return f
    end
  end
  if not quiet then
    log("E","","Could not find facility with id " .. dumps(id))
  end
end

local function getFacilitiesByType(type, levelName)
  levelName = levelName or getCurrentLevelIdentifier()
  if not levelName or levelName == '' then log("E","","Tried to get facility without level!") return end

  local facilities = getFacilities(levelName)
  local listName = facilityTypeToListName[type] or "none"
  if listName == "none" then log("E","","Tried to get facilities of type " .. dumps(type)..", which is not a valid type! ("..dumps(tableKeysSorted(facilityTypeToListName))) end

  return facilities[listName]
end

-- POI integration
local function getZonesForFacility(facility)
  if not facility.sitesFile then log("E","","Facility has not sites file: " .. dumpsz(facility,1)) return end
  local zones = {}

  local sites = {}
  if type(facility.sitesFile) == "string" then
    table.insert(sites, gameplay_sites_sitesManager.loadSites(facility.sitesFile))
  else
    for _, sitesFile in ipairs(facility.sitesFile) do
      table.insert(sites, gameplay_sites_sitesManager.loadSites(sitesFile))
    end
  end

  for _, zoneName in ipairs(facility.zoneNames) do
    local psFound = false
    for _, sitesFromFile in ipairs(sites) do
      local zone = sitesFromFile.zones.byName[zoneName]
      if zone and not zone.missing then
        table.insert(zones, zone)
        psFound = true
        break
      end
    end
    if not psFound then
      log("W","","Missing Spot for facility" .. dumps(facility.id).."?: " .. dumps(zoneName))
    end
  end

  if tableIsEmpty(sites) then
    log("W","","Could not find sites file for facility: " .. dumps(facility.sitesFile))
  end
  return zones
end

local function extractZoneData(facility)
  local success = false
  local zones = {}
  local pos, radius = vec3(), 5
  local zones = getZonesForFacility(facility)
  if zones then
    local aabb = {
      xMin = math.huge, xMax = -math.huge,
      yMin = math.huge, yMax = -math.huge,
      zMin = math.huge, zMax = -math.huge,
      invalid = true}
    for _, zone in ipairs(zones) do
      for i, v in ipairs(zone.vertices) do
        aabb.xMin = math.min(aabb.xMin, v.pos.x)
        aabb.xMax = math.max(aabb.xMax, v.pos.x)
        aabb.yMin = math.min(aabb.yMin, v.pos.y)
        aabb.yMax = math.max(aabb.yMax, v.pos.y)
        aabb.zMin = math.min(aabb.zMin, v.pos.z)
        aabb.zMax = math.max(aabb.zMax, v.pos.z)
        aabb.invalid = false
      end
    end
    if not aabb.invalid then
      pos = vec3((aabb.xMin + aabb.xMax)/2, (aabb.yMin + aabb.yMax)/2, (aabb.zMin + aabb.zMax)/2)
      pos.z = core_terrain.getTerrainHeight(pos) or pos.z
      radius = math.sqrt(((aabb.xMax - aabb.xMin)/2) * ((aabb.xMax - aabb.xMin)/2) + ((aabb.yMax - aabb.yMin)/2) * ((aabb.yMax - aabb.yMin)/2))
      success =true
    elseif next(facility.zoneNames or {}) then
      -- facilities without zoneNames (engine shops, drag strips, passive businesses, racing teams) legitimately have no AABB
      log("E","","AABB is invalid for facility " .. dumps(facility and facility.id) .. " (sites " .. dumps(facility and facility.sitesFile) .. "): " .. dumps(aabb))
    end
  end
  return success, pos, radius, zones
end


local function getGarage(id) return getFacility("garage", id) end
local function getGasStation(id) return getFacility("gasStation", id) end
local function getDealership(id) return getFacility("dealership", id) end


local function getAverageDoorPositionForFacility(facility)
  if not facility then return nil end
  local center, count = vec3(0,0,0), 0

  for _, pair in ipairs(facility.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      center = center + obj:getPosition()
      count = count + 1
    else
      log("W","","Couldnt not find object " .. pair[1] .. " in scenetree for facility " .. facility.id)
    end
  end

  if count > 0 then
    return center / count
  else
    local success, pos = extractZoneData(facility)
    if success then
      return pos
    end
    -- log("D","","Facility has no doors or zones and thus no position! " .. facility.id)
    return nil
  end
end

local function getClosestDoorPositionForFacility(facility)
  if not facility then return nil end
  local camPos = core_camera.getPosition()
  local closest = nil
  local closestDist = math.huge

  for _, pair in ipairs(facility.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      local dist = (obj:getPosition() - camPos):length()
      if dist < closestDist then
        closestDist = dist
        closest = obj:getPosition()
      end
    end
  end
  return closest
end





local function getParkingSpotsForFacility(facility)
  if not facility then return end
  if not facility.sitesFile then log("E","","Facility has not sites file: " .. dumpsz(facility,1)) return end
  local spots = {}

  local sites = {}
  if type(facility.sitesFile) == "string" then
    table.insert(sites, gameplay_sites_sitesManager.loadSites(facility.sitesFile))
  else
    for _, sitesFile in ipairs(facility.sitesFile) do
      table.insert(sites, gameplay_sites_sitesManager.loadSites(sitesFile))
    end
  end
  for _, parkingSpotName in ipairs(facility.parkingSpotNames) do
    local psFound = false
    for _, sitesFromFile in ipairs(sites) do
      local spot = sitesFromFile.parkingSpots.byName[parkingSpotName]
      if spot and not spot.missing then
        table.insert(spots, spot)
        psFound = true
        break
      end
    end
    if not psFound then
      log("W","","Missing Spot for facility" .. dumps(facility.id).."?: " .. dumps(parkingSpotName))
    end
  end
  if tableIsEmpty(sites) then
    log("W","","Could not find sites file for facility: " .. dumps(facility.sitesFile))
  end
  return spots
end

local function getGaragePosRot(poi, veh)
  veh = veh or getPlayerVehicle(0)
  local garage = getGarage(poi.id) -- TODO: implement "default garage" property for level
  if not garage then return end
  local parkingSpots = getParkingSpotsForFacility(garage)
  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(veh:getID(), parkingSpots)
  if parkingSpot then
    return parkingSpot.pos, parkingSpot.rot
  end
  return nil, nil
end

--- Racing team big-map quick travel (QOL skill: qol / quick-travel). Uses team business garage parking.
local function getRacingTeamQuickTravelPosRot(poi, veh)
  if not poi or not poi.id then
    return nil, nil
  end
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return nil, nil
  end
  local st = overhaul_career_business_skillTree
  if not st or not st.getNodeProgress then
    return nil, nil
  end
  local level = tonumber(st.getNodeProgress(poi.id, "qol", "quick-travel")) or 0
  if level < 1 then
    return nil, nil
  end
  local inv = overhaul_career_business_fleet
  if not inv or not inv.getBusinessGaragePosRot then
    return nil, nil
  end
  -- Spot 1 avoids getBestParkingSpotForVehicleFromList (same stall risk as recovery taxi during map/UI init).
  return inv.getBusinessGaragePosRot("racingTeam", poi.id, veh, 1)
end

local function teleportToGarage(garageId, veh, resetVeh, skipTeleportHook)
  if not veh then return false end
  if overhaul_career_permissions then
    local status = overhaul_career_permissions.getStatusForTag("recoveryTowToGarage", {vehId = veh:getID()})
    if not status.allow then return false end
  end
  local pos, rot = getGaragePosRot({id = garageId}, veh)
  if not pos or not rot then return false end

  local dyno = overhaul_career_parts_dyno_dynoSession
  local paused = dyno and dyno.beginGarageTow and dyno.beginGarageTow(veh:getID(), {pos = pos, rot = rot})
  local ok, safeTeleportResult = pcall(spawn.safeTeleport, veh, pos, rot, nil, nil, nil, true, resetVeh)
  if not ok or safeTeleportResult == false then
    if paused then dyno.cancelGarageTow() end
    return false
  end

  core_camera.resetCamera(0)
  if not skipTeleportHook then extensions.hook("onTeleportedToGarage", garageId, veh) end
  if core_groundMarkers.currentlyHasTarget() then
    freeroam_bigMapMode.setNavFocus(core_groundMarkers.endWP[1])
  end
  return true
end
M.teleportToGarage = teleportToGarage

local facilityPoiDefaults = {
  garage = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = true,
    quickTravelPosRotFunction = getGaragePosRot,
    clusterType = 'zoneMarker',
  },
  gasStation = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'gasStationMarker',
  },
  dealership = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'walkingMarker',
  },
  computer = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'walkingMarker',
  },
  deliveryProvider = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'walkingMarker',
  },
  dragstrip = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'vehicleTrigger',
  },
  tuningShop = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'walkingMarker',
  },
  racingTeam = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'walkingMarker',
  },
}

M.zoneMarkerFormatFacility = function(f, elements, bigMapIcon)
  local success, pos, radius, zones = extractZoneData(f)
  if success then
    if type(f.markerPos) == "table" then
      pos = vec3(f.markerPos[1] or 0, f.markerPos[2] or 0, f.markerPos[3] or 0)
    end
    local e = {
      id = f.id,
      data = {type = f.type, facility = f},

      markerInfo = {
        zoneMarker = {zones = zones, pos = pos, radius = radius},
        bigmapMarker = { pos = pos, icon = f.icon,  name = f.name, description = f.description, thumbnail = f.preview, previews = {f.preview}, quickTravelPosRotFunction = getGaragePosRot}
      },
    }
    table.insert(elements, e)
  else
    log("E","","Could not load facility zone data! " .. dumps(f.id))
  end
end


M.walkingMarkerFormatFacility = function(f, elements)

  local center, count = vec3(0,0,0), 0
  for _, pair in ipairs(f.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      center = center + obj:getPosition()
      count = count + 1
    else
      log("W","","Couldnt not find object " .. pair[1] .. " in scenetree for facilitiy " .. f.id)
    end
  end
  if count > 0 then center = center / count end

  local maxDistSqr = 0
  for _, pair in ipairs(f.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      maxDistSqr = math.max(maxDistSqr, (obj:getPosition()-center):squaredLength() + square(pair[3] or 6))
    end
  end
  if count > 0 then
    local facilityCardIcons = {
      computer = "laptop",
      tuningShop = "wrench",
      racingTeam = "raceFlag",
      engineShop = "wrench",
      dealership = "carDealer",
      garage = "garage01",
    }
    local bigmapMarker = {
      pos = center,
      icon = f.icon or f.playModeIconName,
      name = f.name,
      description = f.description,
      thumbnail = f.preview,
      previews = {f.preview},
      cardIcon = facilityCardIcons[f.type],
    }
    if f.type == "racingTeam" and overhaul_career_career and overhaul_career_career.isActive() then
      local st = overhaul_career_business_skillTree
      if st and st.getNodeProgress then
        local qtLevel = tonumber(st.getNodeProgress(f.id, "qol", "quick-travel")) or 0
        if qtLevel > 0 then
          bigmapMarker.quickTravelPosRotFunction = getRacingTeamQuickTravelPosRot
        end
      end
    end
    local e = {
      id = f.id,
      data = {type = f.type, facility = f},
      markerInfo = {
        walkingMarker = { doors = deepcopy(f.doors), iconOffsetHeight = f.iconOffsetHeight, iconLift = f.iconLift, icon = f.playModeIconName or f.icon, pos = center, radius = math.sqrt(maxDistSqr), screens = f.screens, garageId = f.garageId or nil },
        bigmapMarker = bigmapMarker
      }
    }
    table.insert(elements, e)
  else
    log("E","","No objects found for facilitiy " .. f.id .. " ! " .. dumps(f.doors))
  end
end

M.vehicleTriggerFormatFacility = function(f, elements)
  local center, count = vec3(0,0,0), 0
  for _, pair in ipairs(f.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      center = center + obj:getPosition()
      count = count + 1
    else
      log("W","","Couldnt not find object " .. pair[1] .. " in scenetree for facilitiy " .. f.id)
    end
  end
  if count > 0 then center = center / count end

  local maxDistSqr = 0
  for _, pair in ipairs(f.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      maxDistSqr = math.max(maxDistSqr, (obj:getPosition()-center):squaredLength() + square(pair[3] or 6))
    end
  end

  if count > 0 then
    local e = {
      id = f.id,
      data = {type = f.type, facility = f},
      markerInfo = {
        vehicleTrigger = { doors = deepcopy(f.doors), iconOffsetHeight = f.iconOffsetHeight, iconLift = f.iconLift, icon = f.playModeIconName or f.icon, pos = center, radius = math.sqrt(maxDistSqr), screens = f.screens},
        bigmapMarker = {
          pos = center,
          icon = f.icon or f.playModeIconName,
          name = f.name,
          description = f.description,
          thumbnail = f.preview,
          previews = {f.preview},
          cardIcon = f.type == "dragstrip" and "drag02" or nil,
        }
      }
    }
    table.insert(elements, e)
  else
    log("E","","No objects found for facilitiy " .. f.id .. " ! " .. dumps(f.doors))
  end
end


-- Get position for a delivery provider from its sites file (first inspect manualAccessPoint).
local function getDeliveryProviderPosition(f)
  if not f or not f.sitesFile or not f.manualAccessPoints or #f.manualAccessPoints == 0 then
    return nil
  end
  local psName = nil
  for _, ap in ipairs(f.manualAccessPoints) do
    if ap.isInspectSpot and ap.psName then
      psName = ap.psName
      break
    end
  end
  if not psName then
    psName = f.manualAccessPoints[1].psName
  end
  local paths = type(f.sitesFile) == "table" and f.sitesFile or { f.sitesFile }
  for _, sitesPath in ipairs(paths) do
    local sites = gameplay_sites_sitesManager and FS:fileExists(sitesPath) and gameplay_sites_sitesManager.loadSites(sitesPath)
    local spot = sites and sites.parkingSpots and sites.parkingSpots.byName[psName]
    if spot and not spot.missing and spot.pos then
      return vec3(spot.pos)
    end
  end
  return nil
end

local function formatFacilityToRawPoi(f, elements)
  if not f or not facilityPoiDefaults[f.type] then return end
  local e = M[facilityPoiDefaults[f.type].clusterType.."FormatFacility"](f, elements)
  if e then
    -- put in the default values for this facility, if the facility itself did not define it
    for key, value in pairs(facilityPoiDefaults[f.type]) do
      e[key] = f[key]
      if e[key] == nil then
        e[key] = value
      end
    end
    table.insert(elements, e)
  end
end
M.formatFacilityToRawPoi = formatFacilityToRawPoi

-- Returns a shallow copy of the facility whose `doors` only contains entries
-- that are either unlocked (skill node level > 0) or have no lock entry.
-- Returns nil when the facility has zero remaining doors.
local function filterLockedDoors(f)
  if not f or not f.doorLocks or not next(f.doorLocks) then
    return f
  end
  -- Racing team onboarding:
  -- - Before purchase: show both downstairs and upstairs markers.
  -- - After purchase: show upstairs only, until laptop is unlocked.
  if f.type == "racingTeam" and overhaul_career_business_manager then
    local mgr = overhaul_career_business_manager
    local fid = f.id
    local purchased = mgr.isPurchasedBusiness and mgr.isPurchasedBusiness("racingTeam", fid) == true
    if not purchased and mgr.getPurchasedBusinesses then
      local owned = mgr.getPurchasedBusinesses("racingTeam") or {}
      for bid, entry in pairs(owned) do
        if entry == true or type(entry) == "table" then
          if bid == fid or tostring(bid) == tostring(fid) then
            purchased = true
            break
          end
          local nb, nf = tonumber(bid), tonumber(fid)
          if nb and nf and nb == nf then
            purchased = true
            break
          end
        end
      end
    end
    local skillTree = overhaul_career_business_skillTree
    local laptopLv = 0
    if skillTree and skillTree.getNodeProgress then
      local ok, v = pcall(skillTree.getNodeProgress, f.id, "team-operations", "laptop")
      if ok then
        laptopLv = tonumber(v) or 0
      end
    end
    local keepDownstairs = (not purchased) or laptopLv > 0
    local copy = deepcopy(f)
    copy.doors = {}
    for _, pair in ipairs(f.doors or {}) do
      local doorId = pair and pair[1]
      if doorId == "rlsRacingComputer_area1" then
        table.insert(copy.doors, pair) -- upstairs always visible
      elseif doorId == "rlsRacingComputer_area" then
        if keepDownstairs then
          table.insert(copy.doors, pair)
        end
      else
        -- Preserve any other racing-team doors with normal lock behavior.
        local lock = doorId and f.doorLocks[doorId]
        if not lock then
          table.insert(copy.doors, pair)
        else
          local lv = 0
          if skillTree and skillTree.getNodeProgress then
            local ok2, v2 = pcall(skillTree.getNodeProgress, f.id, lock.treeId, lock.nodeId)
            if ok2 then lv = tonumber(v2) or 0 end
          end
          if lv > 0 then
            table.insert(copy.doors, pair)
          end
        end
      end
    end
    if #copy.doors == 0 then
      return nil
    end
    return copy
  end
  local skillTree = overhaul_career_business_skillTree
  local kept = {}
  for _, pair in ipairs(f.doors or {}) do
    local lock = pair and pair[1] and f.doorLocks[pair[1]]
    if lock then
      local lv = 0
      if skillTree and skillTree.getNodeProgress then
        local ok, v = pcall(skillTree.getNodeProgress, f.id, lock.treeId, lock.nodeId)
        if ok then lv = tonumber(v) or 0 end
      end
      if lv > 0 then
        table.insert(kept, pair)
      end
    else
      table.insert(kept, pair)
    end
  end
  if #kept == 0 then return nil end
  local copy = deepcopy(f)
  copy.doors = kept
  return copy
end
M.filterLockedDoors = filterLockedDoors

local function isOverhaulActive()
  return overhaul_shell_gameMode and overhaul_shell_gameMode.isActive and overhaul_shell_gameMode.isActive() or false
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not isOverhaulActive() then return end
  local facilities = getFacilities(levelIdentifier)
  if overhaul_career_career.isActive() then
    for i, dealership in ipairs(facilities.dealerships or {}) do
      local channel = dealership.salesChannel
      if not dealership.remotePurchaseOnly and channel ~= "factory" and channel ~= "remanufactured" then
        M.walkingMarkerFormatFacility(dealership, elements)
      end
    end
    for i, computer in ipairs(facilities.computers or {}) do
      M.walkingMarkerFormatFacility(computer, elements)
    end
    -- Garage zone markers stay off. Playmode garage computers are walking
    -- markers; recovery yards use their sites zone only as a drop-off volume.
    --for i, garage in ipairs(facilities.garages or {}) do
      --M.zoneMarkerFormatFacility(garage, elements, "poi_garage_2")
    --end
  end
  for i, dragstrip in ipairs(facilities.dragstrips or {}) do
    -- Keep both world triggers (history + rules), but only one big-map hub.
    local before = #elements
    M.vehicleTriggerFormatFacility(dragstrip, elements)
    if dragstrip.dragstripPoiType == "rules" and #elements > before then
      local e = elements[#elements]
      if e and e.markerInfo then
        e.markerInfo.bigmapMarker = nil
      end
    end
  end
  if overhaul_career_career.isActive() then
    for i, tuningShop in ipairs(facilities.tuningShops or {}) do
      M.walkingMarkerFormatFacility(tuningShop, elements)
    end
    for i, racingTeam in ipairs(facilities.racingTeams or {}) do
      local visible = filterLockedDoors(racingTeam)
      if visible then
        M.walkingMarkerFormatFacility(visible, elements)
      end
    end
    for _, passiveBusiness in ipairs(facilities.passiveBusinesses or {}) do
      M.walkingMarkerFormatFacility(passiveBusiness, elements)
    end
    for _, engineShop in ipairs(facilities.engineShops or {}) do
      M.walkingMarkerFormatFacility(engineShop, elements)
    end
    for _, certification in ipairs(facilities.engineCertifications or {}) do
      M.walkingMarkerFormatFacility(certification, elements)
    end
    -- Service roles declare their POI presentation independently of shared cargo hubs.
    local roleplayPois
    local function resolveRoleplayPoi(f)
      local org = f.associatedOrganization and overhaul_world_organizations.getOrganization(f.associatedOrganization)
      local role = require('overhaul/lib/logistics/facilityRole').resolve(f, org)
      if not role then return nil end
      roleplayPois = roleplayPois or require('overhaul/lib/jobs/kinds').roleplayPois()
      return roleplayPois[role]
    end

    for _, f in ipairs(facilities.deliveryProviders or {}) do
      local cfg = resolveRoleplayPoi(f)
      local emp = overhaul_career_work_employment
      local blocked = emp and emp.blocksRoleplay and emp.blocksRoleplay()
      if cfg and not blocked then
        local pos = getDeliveryProviderPosition(f)
        if pos then
          table.insert(elements, {
            id = f.id,
            data = { type = cfg.type, missionId = f.id },
            clusterType = "walkingMarker",
            markerInfo = {
              bigmapMarker = {
                pos = pos,
                icon = cfg.icon,
                name = f.name or f.id,
                description = f.description or "",
                thumbnail = f.preview,
                previews = f.preview and { f.preview } or {},
                cardIcon = cfg.cardIcon,
              },
            },
          })
        end
      end
    end
  end
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel

M.onGetRawPoiListForTutorial = function(elements)
  if not isOverhaulActive() then return end
  local level = getCurrentLevelIdentifier()
  if not level then return end
  local facilities = getFacilities(level)
  for i, dragstrip in ipairs(facilities.dragstrips or {}) do
    if dragstrip.isTutorialForDragstrip then
      M.vehicleTriggerFormatFacility(dragstrip, elements)
    end
  end
end

-- Public tuning tents open the tuning UI directly; tuning chooses the vehicle. Refusing to open
-- their computer menu lives in overhaul_career_garage_computer.openMenu, so every caller is covered.
local function openDirectTuning(computerFacility)
  if computerFacility and overhaul_career_parts_tuning then
    overhaul_career_parts_tuning.startAtTent(computerFacility)
  end
end

local function onActivityAcceptGatherData(elemData, activityData)
  if not isOverhaulActive() then return end
  for _, elem in ipairs(elemData) do
    if elem.facility then
      local data = {
        icon = elem.facility.playModeIconName or elem.facility.icon,
        heading = elem.facility.name,
        preheadings = {facilityTypeToUiLabelSingular[elem.facility.type]},
        sorting = {
          type = elem.type,
          id = elem.id
        }
      }
      if elem.type == "garage" then
        data.buttonLabel = "ui.career.openGarageTitle"
        data.buttonFun = function() gameplay_garageMode.start(true) end
        table.insert(activityData, data)
      end
      -- gasStations are handled in gasStations.lua now
      if elem.type == "dealership" then
        -- Some dealerships (Import, Loaned to Owned, ...) define no icon; use the shared one.
        data.icon = data.icon or "poi_entrance_round"
        data.buttonLabel = "ui.facilities.activity.viewInventory"
        data.buttonFun = function() overhaul_career_market_vehicleShopping.openShop(elem.facility.id) end
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props,{
            icon = prop.icon or "checkmark",
            keyLabel = prop.keyLabel,
            valueLabel = prop.valueLabel,
          })
        end
        table.insert(activityData, data)
      end
      if elem.type == "computer" then
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props,{
            icon = prop.icon or "checkmark",
            keyLabel = prop.keyLabel,
            valueLabel = prop.valueLabel,
          })
        end
        if elem.facility.openTuningDirectly then
          data.preheadings = {"Tuning Station"}
          data.buttonLabel = "Tune your vehicle"
          data.buttonFun = function()
            if overhaul_career_career.isActive() then
              openDirectTuning(elem.facility)
            end
          end
        else
          local accessible = overhaul_career_garage_garageManager.isAccessibleGarage(elem.facility.garageId)
          local bundle = require("overhaul/lib/business/bundles").forGarage(elem.facility.garageId)
          data.buttonLabel = accessible and "ui.facilities.activity.useComputer" or (bundle and ("Purchase " .. (bundle.name or bundle.businessId)) or "Purchase Garage")
          -- showPurchaseGaragePrompt refuses notPurchasable garages, so say so instead of a dead button.
          if not accessible and not bundle and overhaul_career_garage_garageManager.isNotPurchasableGarage
              and overhaul_career_garage_garageManager.isNotPurchasableGarage(elem.facility.garageId) then
            data.disabled = true
            data.disableReason = "This garage is not for sale"
          end
          data.buttonFun = function()
            if overhaul_career_career.isActive() then
              if not overhaul_career_garage_garageManager.isAccessibleGarage(elem.facility.garageId) then
                if bundle then
                  overhaul_career_business_manager.showPurchaseBusinessPrompt(bundle.businessType, bundle.businessId)
                else
                  overhaul_career_garage_garageManager.showPurchaseGaragePrompt(elem.facility.garageId)
                end
              else
                overhaul_career_garage_computer.openMenu(elem.facility, false)
              end
            end
          end
        end
        table.insert(activityData, data)
      end
      if elem.type == "dragstrip" then
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props,{
           icon = prop.icon or "drag02",
           keyLabel = prop.keyLabel,
           valueLabel = prop.valueLabel,
         })
        end
        local poiType = elem.facility.dragstripPoiType or "history"
        if poiType == "rules" then
          data.buttonLabel = "ui.facilities.activity.dragstripRulesSetup"
          data.buttonFun = function()
            if gameplay_drag_dragBridge and gameplay_drag_dragBridge.openRulesScreen then
              gameplay_drag_dragBridge.openRulesScreen(elem.facility)
            end
          end
        else
          data.buttonLabel = "ui.facilities.activity.viewHistory"
          data.buttonFun = function()
            gameplay_drag_dragBridge.openHistoryScreen(elem.facility)
          end
        end
        table.insert(activityData, data)
      end
      if elem.type == "tuningShop" then
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props,{
            icon = prop.icon or "checkmark",
            keyLabel = prop.keyLabel,
            valueLabel = prop.valueLabel,
          })
        end
        local tuningInfo = overhaul_career_business_manager.getBusinessInfo("tuningShop", elem.facility.id)
        if overhaul_career_business_manager.isPurchasedBusiness("tuningShop", elem.facility.id) then
          data.heading = (tuningInfo and tuningInfo.name) or elem.facility.name
          data.buttonLabel = "Open " .. ((tuningInfo and tuningInfo.name) or "Tuning Shop")
        else
          data.buttonLabel = "Purchase Business"
        end
        data.buttonFun = function()
          if overhaul_career_career.isActive() then
            if not overhaul_career_business_manager.isPurchasedBusiness("tuningShop", elem.facility.id) then
              overhaul_career_business_manager.showPurchaseBusinessPrompt("tuningShop", elem.facility.id)
            else
              overhaul_career_business_manager.openBusinessMenu("tuningShop", elem.facility.id)
            end
          end
        end
        table.insert(activityData, data)
      end
      if elem.type == "racingTeam" then
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props,{
            icon = prop.icon or "checkmark",
            keyLabel = prop.keyLabel,
            valueLabel = prop.valueLabel,
          })
        end
        local mgr = overhaul_career_business_manager
        local purchased = mgr.isPurchasedBusiness("racingTeam", elem.facility.id) == true
        local racingInfo = mgr.getBusinessInfo("racingTeam", elem.facility.id)
        if purchased then
          local racingName = (racingInfo and racingInfo.name) or elem.facility.name
          if racingName == "Racing Team" then
            racingName = elem.facility.name or racingName
          end
          data.heading = racingName
          data.buttonLabel = "Open"
        else
          data.buttonLabel = "Purchase Business"
        end
        data.buttonFun = function()
          if overhaul_career_career.isActive() then
            if not overhaul_career_business_manager.isPurchasedBusiness("racingTeam", elem.facility.id) then
              overhaul_career_business_manager.showPurchaseBusinessPrompt("racingTeam", elem.facility.id)
            else
              overhaul_career_business_manager.openBusinessMenu("racingTeam", elem.facility.id)
            end
          end
        end
        table.insert(activityData, data)
      end
      if elem.type == "passiveBusiness" then
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props, {
            icon = prop.icon or "checkmark",
            keyLabel = prop.keyLabel,
            valueLabel = prop.valueLabel,
          })
        end
        local mgr = overhaul_career_business_manager
        local purchased = mgr and mgr.isPurchasedBusiness("passiveBusiness", elem.facility.id) == true
        data.buttonLabel = purchased and "Manage Business" or "Purchase Business"
        data.buttonFun = function()
          if not overhaul_career_career.isActive() or not mgr then return end
          if not mgr.isPurchasedBusiness("passiveBusiness", elem.facility.id) then
            mgr.showPurchaseBusinessPrompt("passiveBusiness", elem.facility.id)
          else
            mgr.openBusinessMenu("passiveBusiness", elem.facility.id)
          end
        end
        table.insert(activityData, data)
      end
      if elem.type == "engineShop" then
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props, {icon = prop.icon or "checkmark", keyLabel = prop.keyLabel, valueLabel = prop.valueLabel})
        end
        local mgr = overhaul_career_business_manager
        local purchased = mgr and mgr.isPurchasedBusiness("engineShop", elem.facility.id) == true
        data.buttonLabel = purchased and "Manage Engine Shop" or "Purchase Business"
        data.buttonFun = function()
          if not overhaul_career_career.isActive() or not mgr then return end
          if mgr.isPurchasedBusiness("engineShop", elem.facility.id) then mgr.openBusinessMenu("engineShop", elem.facility.id)
          else mgr.showPurchaseBusinessPrompt("engineShop", elem.facility.id) end
        end
        table.insert(activityData, data)
      end
      if elem.type == "engineCertification" then
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props, {icon = prop.icon or "checkmark", keyLabel = prop.keyLabel, valueLabel = prop.valueLabel})
        end
        local shopId = elem.facility.engineShopId
        local mgr = overhaul_career_business_manager
        local purchased = mgr and mgr.isPurchasedBusiness("engineShop", shopId) == true
        data.buttonLabel = purchased and "Open Certification Handoff" or "Engine Shop Required"
        if not purchased then
          data.disabled = true
          data.disableReason = "Requires owning the engine shop"
        end
        data.buttonFun = function()
          if purchased then mgr.openBusinessMenu("engineShop", shopId) end
        end
        table.insert(activityData, data)
      end
    end
  end
end
M.onActivityAcceptGatherData = onActivityAcceptGatherData

M.getFacilities = getFacilities
M.getCurrentLevelFacilities = function() return getFacilities(getCurrentLevelIdentifier()) end
M.getFacility = getFacility
M.getFacilityIfExists = function(type, id) return getFacility(type, id, true) end
M.getFacilitiesByType = getFacilitiesByType
M.getGarage = getGarage
M.getGasStation = getGasStation
M.getDealership = getDealership
M.getAverageDoorPositionForFacility = getAverageDoorPositionForFacility
M.getClosestDoorPositionForFacility = getClosestDoorPositionForFacility
M.getParkingSpotsForFacility = getParkingSpotsForFacility
M.getZonesForFacility = getZonesForFacility
M.getGaragePosRot = getGaragePosRot

-- Parsed per level, like the game's module that is reloaded with every level.
M.onClientPreStartMission = function()
  facilitiesByLevel = {}
  facilitiesLoadHadLevelInfo = {}
end

local function silenced()
  return function() end
end

M.onExtensionLoaded = function()
  overhaul_shell_patches.registerFields(PATCH_ID, function() return freeroam_facilities end, {
    onGetRawPoiListForLevel = silenced,
    onGetRawPoiListForTutorial = silenced,
    onActivityAcceptGatherData = silenced,
  })
end

M.onExtensionUnloaded = function()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

return M
