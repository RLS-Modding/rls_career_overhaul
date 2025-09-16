-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'gameplay_missions_missions','freeroam_bigMapMode', 'gameplay_rawPois'}


local sendToMinimap = true
local function forceSend() sendToMinimap = true end
M.onClientStartMission = forceSend
M.requestMissionLocationsForMinimap = forceSend

-- Group visibility state storage
local groupVisibilityState = {}

-- Cache variables
local cachedGroupData = nil
local cachedPoiData = nil
local cachedFilters = nil
local cacheValid = false

-- Initialize group visibility state (all groups on by default)
local function initializeGroupVisibility()
  if next(groupVisibilityState) then
    return -- Already initialized
  end

  -- Default groups that should be visible
  local defaultGroups = {
    'rating_new', 'rating_locked', 'rating_attempts', 'rating_done',
    'type_mission', 'type_driftSpots', 'type_dragstrip', 'type_crawl', 'type_spawnPoint',
    'type_garage', 'type_gasStation', 'type_dealership', 'type_playerVehicle', 'type_other',
    'delivery_facility', 'delivery_dropoff',
    'distance_veryClose', 'distance_close', 'distance_medium', 'distance_far', 'distance_veryFar'
  }

  -- Set all default groups to visible
  for _, groupKey in ipairs(defaultGroups) do
    groupVisibilityState[groupKey] = true
  end
end

-- Function to invalidate cache
local function invalidateCache()
  cachedGroupData = nil
  cachedPoiData = nil
  cachedFilters = nil
  cacheValid = false
end

-- Function to check if cache is valid
local function isCacheValid()
  return cacheValid
end

-- Function to set group visibility
M.setGroupVisibility = function(groupKey, isVisible)
  groupVisibilityState[groupKey] = isVisible
end

-- Function to get group visibility
M.getGroupVisibility = function(groupKey)
  return groupVisibilityState[groupKey] ~= false -- Default to true if not set
end

-- Function to toggle group visibility
M.toggleGroupVisibility = function(groupKey)
  local currentState = M.getGroupVisibility(groupKey)
  M.setGroupVisibility(groupKey, not currentState)
  --M.sendCurrentLevelMissionsToBigmap()
  --gameplay_rawPois.clear()
  --freeroam_bigMapMode.setOnlyIdsVisible(M.getAllActiveGroupPoiIds())
end

-- Function to get all active group IDs
M.getActiveGroupIds = function()
  local activeGroups = {}
  for groupKey, isVisible in pairs(groupVisibilityState) do
    if isVisible then
      table.insert(activeGroups, groupKey)
    end
  end
  return activeGroups
end

-- Function to get all group IDs (active and inactive)
M.getAllGroupIds = function()
  local allGroups = {}
  for groupKey, _ in pairs(groupVisibilityState) do
    table.insert(allGroups, groupKey)
  end
  return allGroups
end

M.getAllActiveGroupPoiIds = function()
  -- Ensure cache is built
  if not isCacheValid() then
    M.sendCurrentLevelMissionsToBigmap()
  end
  local poiIds = {}

  -- Use cached data to get POI IDs for active groups
  if cachedGroupData then
    for _, filter in ipairs(cachedFilters) do
      for _, groupKey in ipairs(filter.groups) do
        if groupKey.visible then
          for _, poiId in ipairs(groupKey.elements) do
            table.insert(poiIds, poiId)
          end
        end
      end
    end
  end

  return poiIds
end

-- Function to reset all groups to visible
M.resetAllGroupsToVisible = function()
  for groupKey, _ in pairs(groupVisibilityState) do
    groupVisibilityState[groupKey] = true
  end
end

-- Function to get cached group data
M.getCachedGroupData = function()
  if not isCacheValid() then
    M.sendCurrentLevelMissionsToBigmap()
  end
  return cachedGroupData
end

-- Function to get cached POI data
M.getCachedPoiData = function()
  if not isCacheValid() then
    M.sendCurrentLevelMissionsToBigmap()
  end
  return cachedPoiData
end

-- Function to get cached filters
M.getCachedFilters = function()
  if not isCacheValid() then
    M.sendCurrentLevelMissionsToBigmap()
  end
  return cachedFilters
end

-- Function to manually invalidate cache
M.invalidateCache = invalidateCache

local function sendMissionLocationsToMinimap()
  --[[
  local send = true
  if not gameplay_markerInteraction.isStateFreeroam() or gameplay_missions_missionManager.getForegroundMissionId() then
    send = false
  end
  if send then
    local data = {
      key = 'missions',
      items = {}
    }
    local level = getCurrentLevelIdentifier()
    local i = 1
    for _, cluster in ipairs(gameplay_rawPois.getAllClusters({mergeRadius = 20, levelIdentifier = level})) do
      if cluster.hasType['mission'] then
        data.items[i] = cluster.pos.x
        data.items[i+1] = cluster.pos.y
        data.items[i+2] = cluster.containedIds
        data.items[i+3] = gameplay_rawPois.getIconNamesForCluster(cluster)
        i = i+4
      end
    end
    guihooks.trigger("NavigationStaticMarkers", data)
  else
    M.clearMissionsFromMinimap()
  end
  ]]
  sendToMinimap = false
end

M.sendMissionLocationsToMinimap = sendMissionLocationsToMinimap
M.clearMissionsFromMinimap = function()
  if getCurrentLevelIdentifier() then
    guihooks.trigger("NavigationStaticMarkers", {key = 'missions', items = {}})
  end
end

local poiTypeIcons = {
  spawnPoint = 'fastTravel',
  garage = 'garage01',
  gasStation = 'fuelPump',
  dealership = 'carDealer',
  logisticsParking = 'boxTruckFast',
  logisticsOffice = 'boxTruckFast',
  driftSpot = 'drift01',
  dragstrip = 'drag02',
  crawl = 'mission_rockcrawling01_triangle',
  playerVehicle = 'carStarred',
  other = 'info',
}
M.formatPoiForBigmap = function(poi)
  local bmi = poi.markerInfo.bigmapMarker
  local qtEnabled = (not career_career.isActive()) or (career_modules_linearTutorial.getTutorialFlag('quickTravelEnabled'))
  local icon = bmi.cardIcon or poiTypeIcons[poi.data.type]
  return {
    id = poi.id,
    icon = icon,
    --idInCluster = poi.idInCluster,
    name = bmi.name,
    description = bmi.description,
    thumbnailFile = bmi.thumbnail,
    previewFiles = bmi.previews,
    type = poi.data.type,
    label = '',
    quickTravelAvailable = bmi.quickTravelPosRotFunction and qtEnabled or false,
    quickTravelUnlocked = bmi.quickTravelPosRotFunction and qtEnabled or false,
    canSetRoute = bmi.pos,
    aggregatePrimary = bmi.aggregatePrimary,
    aggregateSecondary = bmi.aggregateSecondary,
  }
end

M.formatMissionForBigmap = function(elemData)
  local mission = gameplay_missions_missions.getMissionById(elemData.missionId)
  local qtEnabled = (not career_career.isActive()) or (career_modules_linearTutorial.getTutorialFlag('quickTravelEnabled'))
  if mission then
    local ret = {
      id = elemData.missionId,
      icon = mission.iconFontIcon,
      --clusterId = elemData.clusterId,
      idInCluster = elemData.idInCluster,
      name = mission.name,
      label = mission.missionTypeLabel or mission.missionType,
      description = mission.description,
      thumbnailFile = mission.thumbnailFile,
      previewFiles = {mission.previewFile},
      type = "mission",
      difficulty = mission.additionalAttributes.difficulty,
      bigmapCycleProgressKeys = mission.bigmapCycleProgressKeys,
      unlocks = mission.unlocks,
      quickTravelAvailable = qtEnabled and true,
      quickTravelUnlocked = qtEnabled and gameplay_missions_progress.missionHasQuickTravelUnlocked(elemData.missionId),
      branchTagsSorted = tableKeysSorted(mission.unlocks.branchTags),
      -- these two will show below the mission and will be a context translation.
      aggregatePrimary = {
        --label = {txt = 'Test', context = {}},
        --value = {txt = 'general.onlyValue', context = {value = '99m'}}
      },
      aggregateSecondary = {
        --label = {txt = 'ui.apps.gears.name', context = {}},
        --value = {txt = 'general.onlyValue', context = {value = '12345'}}
      },
      devMission = mission.devMission or false,

      --[[ rating can have different types: attempts, done, new, stars, with context data.
      rating = {type = 'attempts', attempts = 12345}, -- show attempts: 12345 in this case
      --rating = {type = 'stars', stars = 2}, -- show stars: 2 in this case
      --rating = {type = 'done'}, -- show done
      --rating = {type = 'new'}, -- show new
      ]]
      canSetRoute = true,
    }
    ret.formattedProgress =  gameplay_missions_progress.formatSaveDataForUi(elemData.missionId)
    ret.leaderboardKey = mission.defaultLeaderboardKey or 'recent'


    for key, val in pairs(gameplay_missions_progress.formatSaveDataForBigmap(mission.id) or {}) do
      ret[key] = val
    end
    return ret
  end
  return nil
end

local function getBranchIcons()
  local icons = {money = 'beamCurrency', beamXP = 'beamXP', vouchers = 'voucherHorizontal3'}
  for _, branch in ipairs(career_branches.getSortedBranches()) do
    icons[branch.id] = branch.icon
  end
  return icons
end

local noBranch = "branch_noBranch"

-- Helper function to build group data structure
local function buildGroupData()
  -- Initialize group visibility state if not already done
  initializeGroupVisibility()

  local groupData = {
    rating_new = {label = "Rating: New"},
    rating_locked = {label = "Rating: Locked"},
    rating_attempts = {label = "Rating: Attempted"},
    rating_done = {label = "Rating: Done"},
    type_mission = {label = "Mission"},
    type_driftSpots = {label = "Drift Spots", icon = "drift01"},
    type_dragstrip = {label = "Dragstrips", icon = "drag02"},
    type_crawl = {label = "Crawl Trails", icon = "mission_rockcrawling01_triangle"},
    type_spawnPoint = {label = "Quicktravel Points", icon = "fastTravel"},
    type_garage = {label = "Garages", icon = "garage01"},
    type_gasStation = {label = "Gas Stations", icon = "fuelPump"},
    type_dealership = {label = "Dealerships", icon = "carDealer"},
    type_playerVehicle = {label = "Player Vehicles", icon = "carStarred"},
    type_events = {label = "Free-Roam Events"}, -- Create a type for sections
    type_travel = {label = "Travel Points"},
    type_assignRole = {label = "Role Assignment"},
    type_other = {label = "Other"},

    delivery_facility = {label = "Logistics: Delivery Facility"},
    delivery_dropoff = {label = "Logistics: Delivery Dropoff"},

    distance_veryClose = {label = "Distance: Very Close"},
    distance_close = {label = "Distance: Close"},
    distance_medium = {label = "Distance: Medium"},
    distance_far = {label = "Distance: Far"},
    distance_veryFar = {label = "Distance: Very Far"},
  }

  for _, branch in ipairs(career_branches.getSortedBranches()) do
    if branch and not branch.isDomain then
      local domain = career_branches.getBranchById(branch.parentDomain)
      groupData["branch_"..branch.id] = {label = {txt = "ui.career.domainSlashBranch", context={domain=domain.name, branch=branch.name}}}
    end
  end
  groupData[noBranch] = {label = "Branchless Missions"}

  for _, diff in pairs(gameplay_missions_missions.getAdditionalAttributes().difficulty.valuesByKey) do
    groupData["difficulty_"..diff.key] = {label = "Difficulty: " ..diff.translationKey}
  end
  for _, v in pairs(gameplay_missions_missions.getAdditionalAttributes().vehicle.valuesByKey) do
    groupData["vehicleUsed_"..v.key] = {label = "Vehicle Used: " .. v.translationKey}
  end

  for groupKey, gr in pairs(groupData) do
    gr.elements = {}
  end

  return groupData
end

-- Helper function to process mission POI data
local function processMissionPoi(poi, groupData, playerPos, distanceFilter, difficultyValues)
  local formatted = M.formatMissionForBigmap(poi.data)
  local filterData = {
    groupTags = {},
    sortingValues = {}
  }

  -- distance
  filterData.sortingValues['distance'] = 10--math.max(0,(poi.pos - playerPos):length() - (poi.radius or 0))
  local distLabel = 'veryClose'
  for _, filter in ipairs(distanceFilter) do
    if filterData.sortingValues['distance'] >= filter[1] then
      distLabel = filter[2]
    end
  end
  filterData.groupTags['distance_'..distLabel] = true
  filterData.sortingValues['id'] = poi.id

  filterData.groupTags['type_mission'] = true

  local mission = gameplay_missions_missions.getMissionById(poi.data.missionId)
  -- general data
  filterData.groupTags['missionType_'..mission.missionTypeLabel] = true
  if not groupData['missionType_'..mission.missionTypeLabel] then
    groupData['missionType_'..mission.missionTypeLabel] = {label = mission.missionTypeLabel, elements = {}, visible = M.getGroupVisibility('missionType_'..mission.missionTypeLabel), icon = mission.iconFontIcon}
  end
  if mission.additionalAttributes.difficulty then
    filterData.groupTags['difficulty_'..mission.additionalAttributes.difficulty] = true
    filterData.sortingValues['difficulty'] = difficultyValues[mission.additionalAttributes.difficulty]
  end
  if mission.additionalAttributes.vehicle then
    filterData.groupTags['vehicleUsed_'..mission.additionalAttributes.vehicle] = true
  end
  filterData.sortingValues['depth'] = mission.unlocks.depth

  if career_career.isActive() and mission.careerSetup.skill then
    local skill = career_branches.getBranchById(mission.careerSetup.skill)
    if skill then
      filterData.groupTags['branch_'..skill.id] = true
    end
  end

  filterData.sortingValues['maxBranchTier'] = mission.unlocks.maxBranchlevel
  filterData.groupTags['maxBranchTier_'..mission.unlocks.maxBranchlevel] = true
  groupData['maxBranchTier_'..mission.unlocks.maxBranchlevel] = {label = 'Tier ' .. mission.unlocks.maxBranchlevel, elements = {}, visible = M.getGroupVisibility('maxBranchTier_'..mission.unlocks.maxBranchlevel)}

  -- custom groups/tags
  if mission.grouping.id ~= "" then
    local gId = 'missionGroup_'..mission.grouping.id
    if not groupData[gId] then
      groupData[gId] = {elements = {}, icon = mission.iconFontIcon, visible = M.getGroupVisibility(gId)}
    end
    if mission.grouping.label ~= "" and groupData[gId].label == nil then
      groupData[gId].label = mission.grouping.label
    end
    filterData.groupTags[gId] = true
  end

  -- progress
  if formatted.rating then
    filterData.groupTags['rating_'..formatted.rating.type] = true
  end
  filterData.sortingValues['starCount'] = formatted.rating.totalStars
  filterData.sortingValues['defaultUnlockedStarCount'] = formatted.rating.defaultUnlockedStarCount
  filterData.sortingValues['totalUnlockedStarCount'] = formatted.rating.totalUnlockedStarCount

  return formatted, filterData
end

-- Helper function to process non-mission POI data
local function processNonMissionPoi(poi, groupData, playerPos, distanceFilter)
  local formatted = M.formatPoiForBigmap(poi)
  local filterData = {
    groupTags = {},
    sortingValues = {}
  }

  -- distance
  filterData.sortingValues['distance'] = 10--math.max(0,(poi.pos - playerPos):length() - (poi.radius or 0))
  local distLabel = 'veryClose'
  for _, filter in ipairs(distanceFilter) do
    if filterData.sortingValues['distance'] >= filter[1] then
      distLabel = filter[2]
    end
  end
  filterData.groupTags['distance_'..distLabel] = true
  filterData.sortingValues['id'] = poi.id

  if poi.data.type == 'spawnPoint' then
    filterData.groupTags['type_spawnPoint'] = true
  elseif poi.data.type == 'computer' then
    filterData.groupTags['type_garage'] = true
  elseif poi.data.type == 'gasStation' then
    filterData.groupTags['type_gasStation'] = true
  elseif poi.data.type == 'dealership' then
    filterData.groupTags['type_dealership'] = true
  elseif poi.data.type == "events" then
    filterData.groupTags['type_events'] = true
  elseif poi.data.type == "travel" then
    filterData.groupTags['type_travel'] = true
  elseif poi.data.type == "logisticsParking" then
    filterData.groupTags['delivery_dropoff'] = true
  elseif poi.data.type == "assignRole" then
    filterData.groupTags['type_assignRole'] = true
  elseif poi.data.type == 'logisticsOffice' then
    filterData.groupTags['delivery_facility'] = true
  elseif poi.data.type == "driftSpot" then
    filterData.groupTags['type_driftSpots'] = true
  elseif poi.data.type == "dragstrip" then
    filterData.groupTags['type_dragstrip'] = true
  elseif poi.data.type == "crawl" then
    filterData.groupTags['type_crawl'] = true
  elseif poi.data.type == "playerVehicle" then
    filterData.groupTags['type_playerVehicle'] = true
  else -- other
    filterData.groupTags['type_other'] = true
  end

  return formatted, filterData
end

-- Helper function to build POI data cache
local function buildPoiDataCache(level, groupData)
  local poiData = {}
  local playerPos = core_camera.getPosition()
  local distanceFilter = {
    {25,'close'},
    {100,'medium'},
    {250,'far'},
    {1000,'veryFar'}
  }
  local difficultyValues = {veryLow=0, low=1, medium=2, high=3, veryHigh=4}

  gameplay_rawPois.clear()
  for _, poi in ipairs(gameplay_rawPois.getRawPoiListByLevel(level)) do
    if poi.markerInfo.bigmapMarker then
      local formatted, filterData

      if poi.data.type == 'mission' then
        formatted, filterData = processMissionPoi(poi, groupData, playerPos, distanceFilter, difficultyValues)
      else
        formatted, filterData = processNonMissionPoi(poi, groupData, playerPos, distanceFilter)
      end

      formatted.spriteIcon = poi.markerInfo.bigmapMarker.icon

      poiData[poi.id] = formatted
      poiData[poi.id].filterData = filterData

      for tag, act in pairs(filterData.groupTags) do
        if act then
          if not groupData[tag] then
            log("W","","Unknown group tag: " .. dumps(tag) .. " for poi " .. dumps(poi.id))
            groupData[tag] = {label = tag, elements = {}, visible = M.getGroupVisibility(tag)}
          end
          table.insert(groupData[tag].elements, poi.id)
        end
      end
    end
  end

  -- Sort elements in each group
  for key, gr in pairs(groupData) do
    local elementsAsPois = {}
    for i, id in ipairs(gr.elements) do elementsAsPois[i] = poiData[id] end
    table.sort(elementsAsPois,gameplay_missions_unlocks.depthIdSort)
    for i, poi in ipairs(elementsAsPois) do gr.elements[i] = elementsAsPois[i].id end
  end

  return poiData
end

-- Helper function to build premade filters
local function buildPremadeFilters(groupData)
  local filterFreeroamPois = {
    key = 'freeroamPois',
    icon = 'mapPoint',
    title = 'bigMap.sideMenu.pois',
    groups = {
      groupData['type_spawnPoint'],
      groupData['type_gasStation'],
      groupData['type_other'],
    }
  }

  local filterFreeroamAcitvities = {
    key = 'freeroamActivities',
    icon = 'carFast',
    title = 'Freeroam Activities',
    groups = {
      groupData['type_driftSpots'],
      groupData['type_dragstrip'],
      groupData['type_crawl'],
      groupData['type_events'],
      
    }
  }

  local filterCareerPois = {
    key = 'careerPois',
    icon = 'mapPoint',
    title = 'Career POIs',
    groups = {
      groupData['type_playerVehicle'],
      groupData['type_dealership'],
      groupData['type_garage'],
      groupData['type_gasStation'],
      groupData['type_dragstrip'],
      groupData['type_crawl'],
      groupData['type_events'], -- Added types here for sections
      groupData['type_travel'],
      groupData['type_assignRole'],
      groupData['type_other'],
    }
  }
  local filterMissionsByType = {
    key = 'missionsByType',
    icon = 'flag',
    title = 'Challenges',
    groups = {},
  }
  for _, groupKey in ipairs(tableKeysSorted(groupData)) do
    if string.startswith(groupKey,'missionType_') then
      table.insert(filterMissionsByType.groups, groupData[groupKey])
    end
  end

  return filterFreeroamPois, filterCareerPois, filterMissionsByType, filterFreeroamAcitvities
end

-- Helper function to build career filters
local function buildCareerFilters(groupData, poiData)
  local branchOrdered = career_branches.orderBranchNamesKeysByBranchOrder()
  local domainFilters = {}
  for _, domainId in ipairs(branchOrdered) do
    local domain = career_branches.getBranchById(domainId)
    if domain.isDomain then
      local hasContent = false
      local filter = {
        key = 'domain_'..domainId,
        icon = domain.icon,
        title = domain.name,
        groups = {}
      }
      if domain.id == "logistics" then
        table.insert(filter.groups, groupData['delivery_dropoff'])
        table.insert(filter.groups, groupData['delivery_facility'])
        hasContent = true
      end

      if domain.id == "apm" then
        poiData["apmChallengeInfo"] = {
          id = "apmChallengeInfo",
          type = "apmChallengeInfo",
          name = "APM Challenges",
          description = "APM Challenges and progress can be found in the Career Paths Menu.",
          thumbnailFile = domain.thumbnail,
          previewFiles = {domain.progressCover},
        }
        table.insert(filter.groups, {
          label = "APM Challenges",
          elements = { "apmChallengeInfo" }
        })
        hasContent = true
      end

      for _, branchId in ipairs(branchOrdered) do
        local branch = career_branches.getBranchById(branchId)
        if branch.parentDomain == domainId then
          if groupData['branch_'..branchId] and next(groupData['branch_'..branchId].elements) then
            table.insert(filter.groups, groupData['branch_'..branchId])
            hasContent = true
          end
          if branch.id == "bmra-drift" then
            table.insert(filter.groups, groupData['type_driftSpots'])
            hasContent = true
          end
          if branch.id == "bmra-crawl" then
            table.insert(filter.groups, groupData['type_crawl'])
            hasContent = true
          end
        end
      end
      if hasContent then
        table.insert(domainFilters, filter)
      end
    end
  end

  local filterDelivery = {
    key = 'delivery',
    icon = 'boxTruckFast',
    title = 'Delivery Tasks',
    groups = {
      groupData['delivery_dropoff']
    }
  }

  return domainFilters, filterDelivery
end

-- Function to generate cache data
local function generateCacheData()
  local level = getCurrentLevelIdentifier()

  -- Build group data structure
  local groupData = buildGroupData()

  -- Build POI data cache
  local poiData = buildPoiDataCache(level, groupData)

  -- Build premade filters
  local filterFreeroamPois, filterCareerPois, filterMissionsByType, filterFreeroamAcitvities = buildPremadeFilters(groupData)

  -- Build career filters
  local domainFilters, filterDelivery = buildCareerFilters(groupData, poiData)

  -- Cache the data
  cachedGroupData = groupData
  cachedPoiData = poiData
  cachedFilters = {}

  -- Store filters based on game mode
  if career_career and career_career.isActive() then
    cachedFilters = {filterCareerPois}
    for _, filter in ipairs(domainFilters) do
      table.insert(cachedFilters, filter)
    end
    if career_modules_delivery_general.isDeliveryModeActive() then
      table.insert(cachedFilters, filterDelivery)
    end
  else
    cachedFilters = {filterMissionsByType, filterFreeroamAcitvities, filterFreeroamPois }
  end

  cacheValid = true
end

M.sendCurrentLevelMissionsToBigmap = function()
  -- Invalidate cache when this function is called
  invalidateCache()

  local data = {poiData = {}, levelData = {}, branchIcons = getBranchIcons()}
  local level = getCurrentLevelIdentifier()

  -- Check if we can use cached data
  if isCacheValid() then
    data.poiData = cachedPoiData
    data.filterData = cachedFilters
  else
    -- Generate cache data
    generateCacheData()
    data.poiData = cachedPoiData
    data.filterData = cachedFilters
  end

  for _, lvl in ipairs(core_levels.getList()) do
    if string.lower(lvl.levelName) == getCurrentLevelIdentifier() then
      data.levelData = lvl
    end
  end
  data.gameMode = "freeroam"
  if career_career and career_career.isActive() then
    data.gameMode = "career"
  end
  if gameplay_missions_missionManager.getForegroundMissionId() then
    data.gameMode = "mission"
  end

  -- Update group visibility for cached data
  if cachedGroupData then
    for groupKey, gr in pairs(cachedGroupData) do
      gr.visible = M.getGroupVisibility(groupKey)
      gr.groupKey = groupKey
    end
  end

  -- Set up data rules and filter data
  if career_career and career_career.isActive() then
    data.rules = {
      canSetRoute = not career_modules_testDrive.isActive()
    }

    if career_modules_delivery_general.isDeliveryModeActive() then
      data.selectedFilterKey = "delivery"
    end
  else
    data.rules = {
      canSetRoute = true
    }
  end
  freeroam_bigMapMode.setOnlyIdsVisible(M.getAllActiveGroupPoiIds())
  guihooks.trigger("BigmapMissionData", data)
end


-- gets called only while career mode is enabled
local function onPreRender(dtReal, dtSim)
  if not gameplay_markerInteraction.isStateFreeroam() then
    return
  end
  -- check if we've switched level
  local level = getCurrentLevelIdentifier()
  if level then
    if sendToMinimap then
      M.sendMissionLocationsToMinimap()
    end
  end
end

M.onPreRender = onPreRender
M.forceSend = forceSend
return M