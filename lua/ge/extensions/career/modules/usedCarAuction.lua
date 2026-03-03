local M = {}

M.dependencies = {
  'career_career',
  'career_modules_inventory',
  'career_modules_garageManager',
  'career_modules_payment',
  'career_saveSystem',
  'gameplay_sites_sitesManager',
  'gameplay_traffic',
  'util_configListGenerator'
}

local ENTRY_TRIGGER = 'usedCarAuctionEntry'
local EXIT_TRIGGER = 'usedCarAuctionExit'
local AUCTION_SITES_NAME = 'auction'

local LOT_DURATION = 30
local NPC_BID_COOLDOWN_MIN = 2.0
local NPC_BID_COOLDOWN_MAX = 4.0
local PLAYER_BID_CHECK_INTERVAL = 0.6
local PLAYER_BID_DISTANCE = 18
local FADE_DURATION = 0.35
local ENTRY_RETRIGGER_COOLDOWN = 4.0
local LIVE_STATUS_INTERVAL = 1.0
local LOT_ARRIVE_DISTANCE = 1.5
local LOT_EXIT_DESPAWN_DISTANCE = 5.0
local AI_MAX_SPEED_MPS = 2.2352 -- 5 mph
local LOT_STUCK_TIMEOUT = 5.0
local LOT_PROGRESS_DISTANCE = 0.35
local ANTI_SNIPE_WINDOW = 10.0
local ANTI_SNIPE_EXTEND = 8.0
local ANTI_SNIPE_MAX_EXTENSIONS = 6
local DEFAULT_LOT_COUNT = 3

local fallbackPool = {
  { model = 'covet', config = 'vehicles/covet/roller_covet.pc', title = 'Ibishu Covet', basePrice = 2600 },
  { model = 'hopper', config = 'vehicles/hopper/roller-hopper.pc', title = 'Ibishu Hopper', basePrice = 4200 },
  { model = 'wendover', config = 'vehicles/wendover/roller-wendover.pc', title = 'Gavril Wendover', basePrice = 6400 }
}

local defaultAuctionFilters = {
  filter = {
    whiteList = {
      Mileage = { min = 25000000, max = 380000000 }
    },
    blackList = {
      Type = { 'Trailer', 'Semi Truck' },
      ['Config Type'] = { 'Roller', 'Race', 'Police', 'Service' }
    }
  },
  subFilters = {
    { probability = 7, whiteList = { Mileage = { min = 4800, max = 16093 }, Years = { min = 2010, max = 2025 } } },
    { probability = 6, whiteList = { Mileage = { min = 4800, max = 16093 }, Years = { min = 2000, max = 2009 } } },
    { probability = 5, whiteList = { Mileage = { min = 4800, max = 16093 }, Years = { min = 1990, max = 1999 } } },
    { probability = 4, whiteList = { Mileage = { min = 4800, max = 16093 }, Years = { min = 1980, max = 1989 } } },
    { probability = 3, whiteList = { Mileage = { min = 4800, max = 16093 }, Years = { min = 1970, max = 1979 } } },
    { probability = 2, whiteList = { Mileage = { min = 4800, max = 16093 }, Years = { min = 1950, max = 1969 } } },
    { probability = 1, whiteList = { Mileage = { min = 4800, max = 16093 }, Years = { min = 1900, max = 1949 } } }
  }
}

local auctionState = {
  phase = 'idle',
  lots = {},
  activeLotIndex = 1,
  siteLayout = nil,
  returnTransform = nil,
  auctionSpot = nil,
  travelSpot = nil,
  purchasedInventoryIds = {},
  noSpaceWarnCooldownUntil = 0,
  nextNpcBidAt = 0,
  nextPlayerBidCheckAt = 0,
  nextLiveStatusAt = 0,
  transitionActive = false,
  entryCooldownUntil = 0,
  uiOpen = false,
  awaitingFinalExit = false
}

local usedConfigKeys = {}
local stopVehicleAI

local function deepCopy(src)
  if type(src) ~= 'table' then return src end
  local out = {}
  for k, v in pairs(src) do
    out[k] = deepCopy(v)
  end
  return out
end

local function mergeFilter(baseFilter, subFilter)
  local merged = deepCopy(baseFilter or {})
  merged.whiteList = merged.whiteList or {}
  merged.blackList = merged.blackList or {}

  if subFilter and subFilter.whiteList then
    for k, v in pairs(subFilter.whiteList) do
      merged.whiteList[k] = deepCopy(v)
    end
  end
  if subFilter and subFilter.blackList then
    for k, v in pairs(subFilter.blackList) do
      merged.blackList[k] = deepCopy(v)
    end
  end

  return merged
end

local function getAuctionFilterConfig()
  local level = getCurrentLevelIdentifier() or 'west_coast_usa'
  local path = '/levels/' .. level .. '/auction.filters.json'
  local cfg = jsonReadFile(path)

  if type(cfg) == 'table' then
    return cfg
  end

  return deepCopy(defaultAuctionFilters)
end

local function buildWeightedFilters()
  local cfg = getAuctionFilterConfig()
  local baseFilter = cfg.filter or {}
  local subFilters = cfg.subFilters or {}

  local weighted = {}
  if #subFilters == 0 then
    table.insert(weighted, {prob = 1, filter = deepCopy(baseFilter)})
    return weighted
  end

  for _, sf in ipairs(subFilters) do
    local p = tonumber(sf.probability) or tonumber(sf._probability) or 1
    table.insert(weighted, {
      prob = math.max(0.01, p),
      filter = mergeFilter(baseFilter, sf)
    })
  end

  return weighted
end

local function pickWeightedFilter(weighted)
  if not weighted or #weighted == 0 then
    return {}
  end

  local total = 0
  for _, item in ipairs(weighted) do
    total = total + (item.prob or 1)
  end

  local r = math.random() * total
  local acc = 0
  for _, item in ipairs(weighted) do
    acc = acc + (item.prob or 1)
    if r <= acc then
      return item.filter or {}
    end
  end

  return weighted[#weighted].filter or {}
end

local function setTriggerHidden(triggerName, hidden)
  local trigger = scenetree.findObject(triggerName)
  if trigger then
    trigger:setHidden(hidden and true or false)
  end
end

local function setIdleTriggerState()
  setTriggerHidden(ENTRY_TRIGGER, false)
  setTriggerHidden(EXIT_TRIGGER, true)
end

local function setAuctionRunningTriggerState()
  setTriggerHidden(ENTRY_TRIGGER, true)
  setTriggerHidden(EXIT_TRIGGER, false)
end

local function setAuctionFinishedTriggerState()
  setTriggerHidden(ENTRY_TRIGGER, true)
  setTriggerHidden(EXIT_TRIGGER, false)
end

local function openMenu()
  auctionState.uiOpen = true
  guihooks.trigger('ChangeState', {state = 'used-car-auction'})
end

local function startFadeSafe()
  if ui_fadeScreen and ui_fadeScreen.start then
    pcall(function() ui_fadeScreen.start(FADE_DURATION) end)
  end
end

local function stopFadeSafe()
  if ui_fadeScreen and ui_fadeScreen.stop then
    pcall(function() ui_fadeScreen.stop(FADE_DURATION) end)
  end
end

local function runFadedTransition(workFn)
  if auctionState.transitionActive then
    return
  end

  auctionState.transitionActive = true
  core_jobsystem.create(function(job)
    startFadeSafe()
    job.sleep(FADE_DURATION)

    local ok, err = pcall(workFn)

    stopFadeSafe()
    auctionState.transitionActive = false

    if not ok then
      log('E', 'usedCarAuction', 'Transition failed: ' .. tostring(err))
    end
  end)
end

local function deleteVehicleSafe(vehId)
  if not vehId then return end
  if gameplay_traffic then
    pcall(function() gameplay_traffic.removeTraffic(vehId) end)
  end
  local veh = getObjectByID(vehId)
  if veh then
    pcall(function() veh:delete() end)
  end
end

local function getReturnSpotForInventoryId(inventoryId)
  if not inventoryId then return nil end
  local returnSpots = ((auctionState.siteLayout or {}).returnSpots) or {}
  if #returnSpots == 0 then return nil end

  for idx, invId in ipairs(auctionState.purchasedInventoryIds or {}) do
    if invId == inventoryId then
      return returnSpots[idx]
    end
  end
  return nil
end

local function despawnLotVehicle(lot)
  if not lot then return end
  if lot.wonInventoryId then
    local veh = lot.vehId and getObjectByID(lot.vehId)
    if veh then
      -- Won vehicles stay loaded; park them at return spots for instant availability.
      local returnSpot = getReturnSpotForInventoryId(lot.wonInventoryId)
      if returnSpot and returnSpot.moveResetVehicleTo then
        pcall(function() returnSpot:moveResetVehicleTo(veh:getID(), nil, nil, nil, nil, true) end)
      end
      if gameplay_traffic then
        pcall(function() gameplay_traffic.removeTraffic(veh:getID()) end)
      end
      stopVehicleAI(veh)
      lot.vehId = veh:getID()
      return
    end
  end
  deleteVehicleSafe(lot.vehId)
  lot.vehId = nil
end

local function canAfford(amount)
  if not career_modules_payment then return false end
  return career_modules_payment.canPay({
    money = {
      amount = amount,
      canBeNegative = false
    }
  })
end

local function payForVehicle(amount, label)
  if not career_modules_payment then return false end
  career_modules_payment.pay({
    money = {
      amount = amount,
      canBeNegative = false
    }
  }, {
    label = label,
    tags = {'usedAuction'}
  })
  return true
end

local function getPlayerVehicle()
  return be:getPlayerVehicle(0)
end

local function getSiteParkingSpots()
  local sitePath = gameplay_sites_sitesManager.getCurrentLevelSitesFileByName(AUCTION_SITES_NAME)
  if not sitePath then
    return nil
  end

  local siteData = gameplay_sites_sitesManager.loadSites(sitePath, true, true)
  if not siteData or not siteData.parkingSpots then
    return nil
  end

  local spots = siteData.parkingSpots.sorted or siteData.parkingSpots.objects
  local out = {}
  for _, spot in pairs(spots or {}) do
    if spot and spot.pos and spot.rot then
      table.insert(out, spot)
    end
  end

  return out
end

local function getSpotTags(spot)
  local tags = (((spot or {}).customFields or {}).tags)
  if type(tags) ~= 'table' then
    return {}
  end
  return tags
end

local function hasSpotTag(spot, tag)
  if not spot or not tag then return false end
  local wanted = string.lower(tostring(tag))
  local tags = getSpotTags(spot)

  -- Support both array-style tags {"a","b"} and map-style tags {a=true}.
  for k, v in pairs(tags) do
    local tk = string.lower(tostring(k))
    local tv = string.lower(tostring(v))
    if tv == wanted or tk == wanted then
      return true
    end
  end

  -- Editor fallback: accept spot name matching the desired tag.
  local name = string.lower(tostring(spot.name or ''))
  if name == wanted then
    return true
  end
  return false
end

local function parseTrailingNumber(name)
  local n = tostring(name or ''):match('(%d+)%D*$')
  return tonumber(n)
end

local function sortSpotsByNameAndIndex(spots)
  table.sort(spots, function(a, b)
    local na = parseTrailingNumber(a and a.name)
    local nb = parseTrailingNumber(b and b.name)
    if na and nb and na ~= nb then
      return na < nb
    end
    return tostring((a and a.name) or '') < tostring((b and b.name) or '')
  end)
  return spots
end

local function collectTaggedSpots(spots, tag)
  local out = {}
  for _, spot in ipairs(spots or {}) do
    if hasSpotTag(spot, tag) then
      table.insert(out, spot)
    end
  end
  return sortSpotsByNameAndIndex(out)
end

local function firstSpotWithTag(spots, tags)
  for _, tag in ipairs(tags or {}) do
    local list = collectTaggedSpots(spots, tag)
    if #list > 0 then
      return list[1]
    end
  end
  return nil
end

local function buildSiteLayout(spots)
  local layout = {
    allSpots = spots or {},
    playerSpot = nil,
    spawnSpots = {},
    blockSpots = {},
    pathInSpots = {},
    pathOutSpots = {},
    despawnSpot = nil,
    returnSpots = {}
  }

  layout.playerSpot = firstSpotWithTag(spots, {'auctionPlayerStart'})
  layout.spawnSpots = collectTaggedSpots(spots, 'auctionSpawn')
  layout.blockSpots = collectTaggedSpots(spots, 'auctionBlock')

  layout.pathInSpots = collectTaggedSpots(spots, 'auctionPathIn')
  layout.pathOutSpots = collectTaggedSpots(spots, 'auctionPathOut')
  layout.despawnSpot = firstSpotWithTag(spots, {'auctionDespawn'})

  layout.returnSpots = collectTaggedSpots(spots, 'auctionReturn')

  return layout
end

local function teleportVehicleToSpot(veh, spot)
  if not veh or not spot then return false end

  local pos = vec3(spot.pos)
  local rot = quat(0, 0, 1, 0) * quat(spot.rot)
  veh:setPosRot(pos.x, pos.y, pos.z + 0.5, rot.x, rot.y, rot.z, rot.w)
  veh:queueLuaCommand('electrics.setIgnitionLevel(0)')
  return true
end

stopVehicleAI = function(veh)
  if not veh then return end
  veh:queueLuaCommand('ai.setMode("stop")')
  veh:queueLuaCommand('electrics.setIgnitionLevel(0)')
  veh:queueLuaCommand('electrics.setLightsState(1)')
end

local function getRoadPathNodes(startPos, endPos)
  if not map or not map.findClosestRoad or not map.getPath then
    return nil
  end

  local startRoad = select(1, map.findClosestRoad(startPos))
  local endRoad = select(1, map.findClosestRoad(endPos))
  if not startRoad or not endRoad then
    return nil
  end

  local path = map.getPath(startRoad, endRoad)
  if type(path) ~= 'table' or #path < 2 then
    return nil
  end
  return path
end

local function driveVehicleToSpot(veh, fromSpot, toSpot, aggression)
  if not veh or not fromSpot or not toSpot then return false end

  local path = getRoadPathNodes(vec3(fromSpot.pos), vec3(toSpot.pos))
  if not path or #path < 2 then
    return false
  end

  local pathStr = '{path = ' .. serialize(path)
  pathStr = pathStr .. string.format(', noOfLaps = 1, aggression = %.2f, avoidCars = "on"}', aggression or 0.4)
  veh:queueLuaCommand('ai.driveUsingPath(' .. pathStr .. ')')
  veh:queueLuaCommand('ai.setRacing(false)')
  veh:queueLuaCommand('ai.driveInLane("on")')
  veh:queueLuaCommand('ai.setSpeedMode("set")')
  veh:queueLuaCommand(string.format('ai.setSpeed(%.4f)', AI_MAX_SPEED_MPS))
  return true
end

local function driveVehicleAlongRouteSpots(veh, routeSpots, aggression)
  if not veh or type(routeSpots) ~= 'table' or #routeSpots < 2 then
    return false
  end

  local combinedPath = {}
  for i = 1, #routeSpots - 1 do
    local segPath = getRoadPathNodes(vec3(routeSpots[i].pos), vec3(routeSpots[i + 1].pos))
    if segPath and #segPath >= 2 then
      for j, nodeId in ipairs(segPath) do
        if j == 1 and #combinedPath > 0 and combinedPath[#combinedPath] == nodeId then
          -- avoid duplicate touching nodes between segments
        else
          table.insert(combinedPath, nodeId)
        end
      end
    end
  end

  if #combinedPath < 2 then
    return false
  end

  local pathStr = '{path = ' .. serialize(combinedPath)
  pathStr = pathStr .. string.format(', noOfLaps = 1, aggression = %.2f, avoidCars = "on"}', aggression or 0.4)
  veh:queueLuaCommand('ai.driveUsingPath(' .. pathStr .. ')')
  veh:queueLuaCommand('ai.setRacing(false)')
  veh:queueLuaCommand('ai.driveInLane("on")')
  veh:queueLuaCommand('ai.setSpeedMode("set")')
  veh:queueLuaCommand(string.format('ai.setSpeed(%.4f)', AI_MAX_SPEED_MPS))
  return true
end

local function getVehicleConfigPath(info)
  if not info or not info.model_key or not info.key then
    return nil
  end

  local key = tostring(info.key)
  key = key:gsub('%.pc$', '')
  local candidatePaths = {
    '/vehicles/' .. info.model_key .. '/configurations/' .. key .. '.pc',
    '/vehicles/' .. info.model_key .. '/' .. key .. '.pc'
  }

  for _, path in ipairs(candidatePaths) do
    if FS:fileExists(path) then
      return path
    end
  end

  return nil
end

local function isRollerLikeInfo(info)
  local a = string.lower(tostring(info.key or ''))
  local b = string.lower(tostring(info.Name or ''))
  local c = string.lower(tostring(info['Config Type'] or ''))

  return a:find('roller', 1, true) or b:find('roller', 1, true) or c:find('roller', 1, true)
end

local function getMileageFromInfo(info)
  if not info then return nil end
  local mileage = tonumber(info.Mileage) or tonumber(info.mileage) or tonumber(info['Mileage'])
  if not mileage then return nil end
  -- config-list mileage is often in meters; normalize to miles for UI display
  if mileage > 2000000 then
    mileage = mileage / 1609.344
  end
  mileage = math.max(0, math.floor(mileage))
  if mileage <= 0 then return nil end
  return mileage
end

local function getFallbackMileage()
  return math.random(5000, 180000)
end

local function getRandomVehicleDefWithFilter(filter)
  local eligibleVehicles = util_configListGenerator.getEligibleVehicles(false, false)
  local infos = util_configListGenerator.getRandomVehicleInfos({filter = filter or {}}, 40, eligibleVehicles, 'Population')

  for _, info in ipairs(infos or {}) do
    local configPath = getVehicleConfigPath(info)
    if configPath and (not usedConfigKeys[configPath]) and (not isRollerLikeInfo(info)) then
      usedConfigKeys[configPath] = true

      local brand = tostring(info.Brand or '')
      local name = tostring(info.Name or info.key or info.model_key)
      local title = ((brand ~= '' and (brand .. ' ') or '') .. name)

      return {
        model = info.model_key,
        config = configPath,
        title = title,
        basePrice = math.max(1500, math.floor(tonumber(info.Value or 4500))),
        mileage = getMileageFromInfo(info) or getFallbackMileage()
      }
    end
  end

  return nil
end

local function getGarageFreeSlots()
  if career_modules_inventory and career_modules_inventory.hasFreeSlot then
    if not career_modules_inventory.hasFreeSlot() then
      return 0
    end
  end

  if career_modules_garageManager and career_modules_garageManager.getFreeSlots then
    return math.max(0, tonumber(career_modules_garageManager.getFreeSlots()) or 0)
  end

  return 0
end

local function hasGarageSpaceForPurchase()
  return getGarageFreeSlots() > 0
end

local function getRandomVehicleDefNoFilter()
  local eligibleVehicles = util_configListGenerator.getEligibleVehicles(false, false)
  local infos = util_configListGenerator.getRandomVehicleInfos({filter = {}}, 80, eligibleVehicles, 'Population')

  for _, info in ipairs(infos or {}) do
    local configPath = getVehicleConfigPath(info)
    if configPath and (not usedConfigKeys[configPath]) and (not isRollerLikeInfo(info)) then
      usedConfigKeys[configPath] = true

      local brand = tostring(info.Brand or '')
      local name = tostring(info.Name or info.key or info.model_key)
      local title = ((brand ~= '' and (brand .. ' ') or '') .. name)

      return {
        model = info.model_key,
        config = configPath,
        title = title,
        basePrice = math.max(1500, math.floor(tonumber(info.Value or 4500))),
        mileage = getMileageFromInfo(info) or getFallbackMileage()
      }
    end
  end

  return nil
end

local function prepareLots(spawnSpots, blockSpots, lotCount)
  local lots = {}
  local spawnCount = #(spawnSpots or {})
  if spawnCount <= 0 then
    return lots
  end

  lotCount = math.max(1, tonumber(lotCount) or DEFAULT_LOT_COUNT)
  local blockCount = #(blockSpots or {})
  local weightedFilters = buildWeightedFilters()

  table.clear(usedConfigKeys)

  for i = 1, lotCount do
    local spawnSpot = spawnSpots[((i - 1) % spawnCount) + 1]
    local blockSpot = spawnSpot
    if blockCount > 0 then
      blockSpot = blockSpots[((i - 1) % blockCount) + 1]
    end

    local lotFilter = pickWeightedFilter(weightedFilters)
    local vehicleDef = getRandomVehicleDefWithFilter(lotFilter)
    if not vehicleDef then
      vehicleDef = getRandomVehicleDefNoFilter()
    end
    if not vehicleDef then
      vehicleDef = fallbackPool[math.random(1, #fallbackPool)]
    end

    local startBid = math.floor(vehicleDef.basePrice * (0.55 + math.random() * 0.2))
    local aiStyleRoll = math.random()
    local npcMaxMult = 1.0
    if aiStyleRoll < 0.20 then
      npcMaxMult = 1.15 + math.random() * 0.30 -- aggressive / occasional overpay
    elseif aiStyleRoll < 0.70 then
      npcMaxMult = 0.90 + math.random() * 0.25 -- typical market behavior
    else
      npcMaxMult = 0.65 + math.random() * 0.30 -- conservative / bargain hunter
    end
    local npcMaxBid = math.floor(vehicleDef.basePrice * npcMaxMult)

    table.insert(lots, {
      lotIndex = i,
      spawnSpot = spawnSpot,
      blockSpot = blockSpot,
      model = vehicleDef.model,
      config = vehicleDef.config,
      title = vehicleDef.title,
      mileage = vehicleDef.mileage or getFallbackMileage(),
      minStep = 250,
      currentBid = startBid,
      highestBidder = 'npc',
      npcMaxBid = npcMaxBid,
      extensionCount = 0,
      maxExtensions = ANTI_SNIPE_MAX_EXTENSIONS,
      endTime = 0,
      state = 'pending',
      vehId = nil,
      wonByPlayer = false,
      wonInventoryId = nil,
      driveState = nil,
      driveStartedAt = 0,
      lastMotionPos = nil,
      lastMotionAt = 0
    })
  end

  return lots
end

local showLiveAuctionStatus

local function maybeExtendLotTimer(lot, bidderLabel)
  if not lot or lot.state ~= 'active' then return false end
  local now = os.clock()
  local remaining = (lot.endTime or 0) - now
  if remaining > ANTI_SNIPE_WINDOW then
    return false
  end
  if (lot.extensionCount or 0) >= (lot.maxExtensions or ANTI_SNIPE_MAX_EXTENSIONS) then
    return false
  end

  lot.endTime = (lot.endTime or now) + ANTI_SNIPE_EXTEND
  lot.extensionCount = (lot.extensionCount or 0) + 1
  ui_message(string.format('%s bid extended auction by %.0fs (%d/%d).',
    bidderLabel or 'Bid',
    ANTI_SNIPE_EXTEND,
    lot.extensionCount,
    lot.maxExtensions or ANTI_SNIPE_MAX_EXTENSIONS), 2.5, 'Used Auction', 'info')
  return true
end

local function getConfigKeyFromPath(configPath)
  if type(configPath) ~= 'string' then return nil end
  local normalized = configPath:gsub('\\', '/')
  local key = normalized:match('/configurations/([^/]+)%.pc$')
  if key then
    return key
  end
  return normalized:match('/([^/]+)%.pc$')
end

local function applyRandomPaintToSpawnOptions(options, modelKey, configPath)
  if not options or not modelKey then return end
  if not core_vehiclePaints or not core_vehiclePaints.getRandomPaints then return end

  local paintResult = core_vehiclePaints.getRandomPaints(modelKey, getConfigKeyFromPath(configPath))
  if type(paintResult) ~= 'table' then return end

  local modelData = core_vehicles.getModel(modelKey)
  local modelPaints = modelData and modelData.model and modelData.model.paints
  if type(modelPaints) ~= 'table' then return end

  local paintNames = {paintResult.paintName1, paintResult.paintName2, paintResult.paintName3}
  local paint1 = paintNames[1] and modelPaints[paintNames[1]]
  local paint2 = paintNames[2] and modelPaints[paintNames[2]]
  local paint3 = paintNames[3] and modelPaints[paintNames[3]]
  if not paint1 then
    return
  end

  options.paintName = paintNames[1]
  options.paintName2 = paintNames[2]
  options.paintName3 = paintNames[3]
  options.paint = deepCopy(paint1)
  options.paint2 = deepCopy(paint2 or paint1)
  options.paint3 = deepCopy(paint3 or paint1)

  -- Also embed paints into config data before spawn so loaded config keeps auction paint.
  if type(configPath) == 'string' then
    local cfg = jsonReadFile(configPath)
    if type(cfg) == 'table' and cfg.format ~= 4 then
      cfg = deepCopy(cfg)
      cfg.partConfigFilename = configPath
      cfg.colors = nil
      cfg.paints = {
        deepCopy(options.paint),
        deepCopy(options.paint2),
        deepCopy(options.paint3)
      }
      options.config = cfg
    end
  end
end

local function spawnLotVehicle(lot, spot, startApproach)
  if not lot then return false end
  local spawnSpot = spot or lot.spawnSpot
  local options = {
    config = lot.config,
    autoEnterVehicle = false,
    autoFlip = true,
    pos = vec3(spawnSpot.pos),
    rot = quat(spawnSpot.rot)
  }

  -- Pick and inject random paint before spawn so it becomes part of spawn config.
  pcall(function()
    applyRandomPaintToSpawnOptions(options, lot.model, lot.config)
  end)

  local veh = core_vehicles.spawnNewVehicle(lot.model, options)
  if not veh then
    lot.state = 'failed'
    return false
  end

  lot.vehId = veh:getID()
  lot.state = startApproach and 'approaching' or 'queued'
  lot.driveState = startApproach and 'approach' or nil
  lot.driveStartedAt = os.clock()
  lot.lastMotionPos = vec3(veh:getPosition())
  lot.lastMotionAt = lot.driveStartedAt
  gameplay_traffic.insertTraffic(lot.vehId, true)
  veh.playerUsable = true
  veh:queueLuaCommand('electrics.setLightsState(1)')
  if startApproach then
    veh:queueLuaCommand('ai.setSpeedMode("set")')
    veh:queueLuaCommand(string.format('ai.setSpeed(%.4f)', AI_MAX_SPEED_MPS))
  else
    stopVehicleAI(veh)
  end

  return true
end

local function beginLotBidding(lot, forceTeleportToBlock)
  if not lot then return end
  local veh = lot.vehId and getObjectByID(lot.vehId)
  if veh then
    if forceTeleportToBlock then
      teleportVehicleToSpot(veh, lot.blockSpot or lot.spawnSpot)
    end
    stopVehicleAI(veh)
  end

  lot.state = 'active'
  lot.driveState = nil
  lot.endTime = os.clock() + LOT_DURATION
  auctionState.nextNpcBidAt = os.clock() + 1.0
  auctionState.nextPlayerBidCheckAt = os.clock() + 0.5
  auctionState.nextLiveStatusAt = 0
  ui_message(string.format('Now auctioning: %s', lot.title), 5, 'Used Auction', 'info')
  showLiveAuctionStatus(true)
end

local function beginLotApproach(lot)
  if not lot then return false end
  local veh = lot.vehId and getObjectByID(lot.vehId)
  if not veh then return false end
  lot.state = 'approaching'
  lot.driveState = 'approach'
  lot.driveStartedAt = os.clock()
  lot.lastMotionPos = vec3(veh:getPosition())
  lot.lastMotionAt = lot.driveStartedAt

  local routeSpots = {}
  table.insert(routeSpots, lot.spawnSpot)
  for _, spot in ipairs((auctionState.siteLayout and auctionState.siteLayout.pathInSpots) or {}) do
    table.insert(routeSpots, spot)
  end
  table.insert(routeSpots, lot.blockSpot or lot.spawnSpot)

  if driveVehicleAlongRouteSpots(veh, routeSpots, 0.35) then
    return true
  end

  if lot.spawnSpot and (lot.blockSpot or lot.spawnSpot) and driveVehicleToSpot(veh, lot.spawnSpot, lot.blockSpot or lot.spawnSpot, 0.35) then
    return true
  end

  beginLotBidding(lot, true)
  return false
end

local function beginLotExit(lot)
  if not lot then return false end

  local veh = lot.vehId and getObjectByID(lot.vehId)
  if not veh then
    lot.state = 'finished'
    lot.driveState = 'done'
    return false
  end

  lot.state = 'exiting'
  lot.driveState = 'exit'
  lot.driveStartedAt = os.clock()
  lot.lastMotionPos = vec3(veh:getPosition())
  lot.lastMotionAt = lot.driveStartedAt

  local routeSpots = {}
  table.insert(routeSpots, lot.blockSpot or lot.spawnSpot)
  for _, spot in ipairs((auctionState.siteLayout and auctionState.siteLayout.pathOutSpots) or {}) do
    table.insert(routeSpots, spot)
  end
  if auctionState.siteLayout and auctionState.siteLayout.despawnSpot then
    table.insert(routeSpots, auctionState.siteLayout.despawnSpot)
  end

  if driveVehicleAlongRouteSpots(veh, routeSpots, 0.45) then
    return true
  end

  if auctionState.siteLayout and auctionState.siteLayout.despawnSpot and driveVehicleToSpot(veh, lot.blockSpot or lot.spawnSpot, auctionState.siteLayout.despawnSpot, 0.45) then
    return true
  end

  despawnLotVehicle(lot)
  lot.state = 'finished'
  lot.driveState = 'done'
  return false
end

local function setAuctionComplete()
  if auctionState.phase == 'complete' then return end
  auctionState.phase = 'complete'
  auctionState.awaitingFinalExit = false
  setAuctionFinishedTriggerState()
  ui_message('Auction complete. Enter exit trigger to return.', 7, 'Used Auction', 'info')
end

local function startLotByIndex(idx)
  local lot = auctionState.lots[idx]
  if not lot then
    return false
  end

  if lot.vehId and getObjectByID(lot.vehId) then
    beginLotApproach(lot)
    return true
  end

  if spawnLotVehicle(lot, lot.spawnSpot, true) then
    beginLotApproach(lot)
    return true
  end

  lot.state = 'failed'
  return false
end

local function startNextLotAfter(currentLotIndex)
  local idx = (tonumber(currentLotIndex) or 0) + 1
  while true do
    local nextLot = auctionState.lots[idx]
    if not nextLot then
      auctionState.awaitingFinalExit = true
      return false
    end

    auctionState.activeLotIndex = idx
    if startLotByIndex(idx) then
      return true
    end

    idx = idx + 1
  end
end

showLiveAuctionStatus = function(force)
  if auctionState.phase ~= 'bidding' then return end

  local now = os.clock()
  if not force and now < (auctionState.nextLiveStatusAt or 0) then
    return
  end

  local lot = auctionState.lots[auctionState.activeLotIndex]
  if not lot or lot.state ~= 'active' then
    return
  end

  local remaining = math.max(0, math.ceil((lot.endTime or 0) - now))
  local bidder = (lot.highestBidder == 'player') and 'YOU' or 'NPC'
  local totalLots = #auctionState.lots
  local msg = string.format('Auction Active | Lot %d/%d | %s | Bid $%d | %ds left | Leader %s',
    lot.lotIndex, totalLots, lot.title, lot.currentBid, remaining, bidder)

  guihooks.trigger('Message', {
    ttl = 1.1,
    category = 'usedAuctionLive',
    icon = 'timer',
    msg = msg
  })

  auctionState.nextLiveStatusAt = now + LIVE_STATUS_INTERVAL
end

local function placePlayerBidIfPossible()
  if auctionState.phase ~= 'bidding' then
    return false
  end

  local lot = auctionState.lots[auctionState.activeLotIndex]
  if not lot or lot.state ~= 'active' or lot.highestBidder == 'player' then
    return false
  end

  local bidAmount = lot.currentBid + lot.minStep
  if not hasGarageSpaceForPurchase() then
    local now = os.clock()
    if now >= (auctionState.noSpaceWarnCooldownUntil or 0) then
      ui_message('No garage space available. Buy/sell or free a slot before bidding.', 4, 'Used Auction', 'warning')
      auctionState.noSpaceWarnCooldownUntil = now + 3.5
    end
    return false
  end

  if not canAfford(bidAmount) then
    return false
  end

  lot.currentBid = bidAmount
  lot.highestBidder = 'player'
  maybeExtendLotTimer(lot, 'Player')
  auctionState.nextNpcBidAt = os.clock() + (NPC_BID_COOLDOWN_MIN + math.random() * (NPC_BID_COOLDOWN_MAX - NPC_BID_COOLDOWN_MIN))
  ui_message(string.format('Bid placed on %s: $%d', lot.title, bidAmount), 2, 'Used Auction', 'info')
  showLiveAuctionStatus(true)
  return true
end

local function placePlayerBidByAmount(amount)
  if auctionState.phase ~= 'bidding' then return false end
  local lot = auctionState.lots[auctionState.activeLotIndex]
  if not lot or lot.state ~= 'active' or lot.highestBidder == 'player' then
    return false
  end

  amount = math.max(lot.minStep or 250, tonumber(amount) or 0)
  local bidAmount = lot.currentBid + amount

  if not hasGarageSpaceForPurchase() then return false end
  if not canAfford(bidAmount) then return false end

  lot.currentBid = bidAmount
  lot.highestBidder = 'player'
  maybeExtendLotTimer(lot, 'Player')
  auctionState.nextNpcBidAt = os.clock() + (NPC_BID_COOLDOWN_MIN + math.random() * (NPC_BID_COOLDOWN_MAX - NPC_BID_COOLDOWN_MIN))
  ui_message(string.format('Bid placed on %s: $%d', lot.title, bidAmount), 2, 'Used Auction', 'info')
  showLiveAuctionStatus(true)
  return true
end

local function requestAuctionState()
  local now = os.clock()
  local lotsOut = {}
  local derivedCurrentLot = nil
  local derivedCurrentLotIndex = nil
  for _, lot in ipairs(auctionState.lots or {}) do
    local lotOut = {
      lotIndex = lot.lotIndex,
      title = lot.title,
      mileage = lot.mileage,
      state = lot.state,
      currentBid = lot.currentBid or 0,
      minStep = lot.minStep or 250,
      highestBidder = lot.highestBidder,
      timeLeft = math.max(0, math.ceil((lot.endTime or 0) - now))
    }
    table.insert(lotsOut, lotOut)

    if not derivedCurrentLot and (lot.state == 'queued' or lot.state == 'approaching' or lot.state == 'active' or lot.state == 'exiting') then
      derivedCurrentLot = lotOut
      derivedCurrentLotIndex = lotOut.lotIndex
    end
  end

  local indexedLot = lotsOut[(auctionState.activeLotIndex or 1)]
  if indexedLot and (indexedLot.state == 'queued' or indexedLot.state == 'approaching' or indexedLot.state == 'active' or indexedLot.state == 'exiting') then
    derivedCurrentLot = indexedLot
    derivedCurrentLotIndex = indexedLot.lotIndex
  end

  local hasLiveLot = derivedCurrentLot ~= nil
  local derivedPhase = auctionState.phase
  if hasLiveLot and (derivedPhase == 'idle' or derivedPhase == 'starting') then
    derivedPhase = 'bidding'
  end

  local status = 'Enter the auction trigger to begin.'
  if derivedPhase == 'bidding' then
    status = 'Auction in progress.'
  elseif derivedPhase == 'complete' then
    status = 'Auction complete. Use exit trigger to return.'
  end

  return {
    phase = derivedPhase,
    activeLotIndex = auctionState.activeLotIndex,
    currentLotIndex = derivedCurrentLotIndex,
    hasLiveLot = hasLiveLot,
    currentLot = derivedCurrentLot,
    statusMessage = status,
    purchasedCount = #(auctionState.purchasedInventoryIds or {}),
    lots = lotsOut
  }
end

local function placeBid(amount)
  if amount and tonumber(amount) and tonumber(amount) > 0 then
    return placePlayerBidByAmount(tonumber(amount))
  end
  return placePlayerBidIfPossible()
end

local function passCurrentLot()
  if auctionState.phase ~= 'bidding' then return false end
  local lot = auctionState.lots[auctionState.activeLotIndex]
  if not lot or lot.state ~= 'active' then return false end
  lot.highestBidder = 'npc'
  lot.endTime = os.clock()
  return true
end

local function closeMenu()
  auctionState.uiOpen = false
  if career_career and career_career.closeAllMenus then
    pcall(function() career_career.closeAllMenus() end)
  end
  pcall(function() guihooks.trigger('UINavigation', 'back', 1) end)
  pcall(function() guihooks.trigger('ChangeState', {state = 'play'}) end)
end

local function startAuction()
  if auctionState.phase == 'idle' then
    return startAuctionImmediate()
  end
  return false
end

local function cancelTravelPrompt()
  closeMenu()
  return true
end

local function finishCurrentLot()
  local lot = auctionState.lots[auctionState.activeLotIndex]
  if not lot or lot.state ~= 'active' then
    return
  end

  lot.state = 'finished'

  if lot.highestBidder == 'player' then
    if not hasGarageSpaceForPurchase() then
      ui_message(string.format('No garage space for %s. Bid canceled.', lot.title), 6, 'Used Auction', 'warning')
    elseif canAfford(lot.currentBid) then
      payForVehicle(lot.currentBid, string.format('Used Auction: %s', lot.title))
      local inventoryId = career_modules_inventory.addVehicle(lot.vehId, nil, {owned = true})
      if inventoryId then
        if not career_modules_inventory.moveVehicleToGarage(inventoryId) then
          career_modules_inventory.removeVehicle(inventoryId)
          ui_message(string.format('No garage space for %s at close.', lot.title), 6, 'Used Auction', 'warning')
          beginLotExit(lot)
          startNextLotAfter(lot.lotIndex)
          return
        end
        lot.wonByPlayer = true
        lot.wonInventoryId = inventoryId
        table.insert(auctionState.purchasedInventoryIds, inventoryId)
        ui_message(string.format('Won %s for $%d', lot.title, lot.currentBid), 6, 'Used Auction', 'info')
      else
        ui_message(string.format('Purchase failed for %s', lot.title), 6, 'Used Auction', 'warning')
      end
    else
      ui_message(string.format('Could not afford %s at close', lot.title), 6, 'Used Auction', 'warning')
    end
  else
    ui_message(string.format('Lost %s (sold for $%d)', lot.title, lot.currentBid), 5, 'Used Auction', 'info')
  end

  beginLotExit(lot)
  startNextLotAfter(lot.lotIndex)
end

local function resetAuction(keepPurchases)
  for _, lot in ipairs(auctionState.lots) do
    if lot.vehId then
      local keepVeh = false
      if keepPurchases then
        for _, invId in ipairs(auctionState.purchasedInventoryIds) do
          local savedVehId = career_modules_inventory.getVehicleIdFromInventoryId(invId)
          if savedVehId and savedVehId == lot.vehId then
            keepVeh = true
            break
          end
        end
      end

      if not keepVeh then
        deleteVehicleSafe(lot.vehId)
      end
    end
  end

  auctionState.phase = 'idle'
  auctionState.lots = {}
  auctionState.activeLotIndex = 1
  auctionState.siteLayout = nil
  auctionState.returnTransform = nil
  auctionState.auctionSpot = nil
  auctionState.travelSpot = nil
  auctionState.nextNpcBidAt = 0
  auctionState.nextPlayerBidCheckAt = 0
  auctionState.nextLiveStatusAt = 0
  auctionState.noSpaceWarnCooldownUntil = 0
  auctionState.awaitingFinalExit = false

  if not keepPurchases then
    auctionState.purchasedInventoryIds = {}
  end

  setIdleTriggerState()
end

local function startAuctionImmediate()
  if auctionState.phase ~= 'idle' or auctionState.transitionActive then
    return false
  end

  local playerVeh = getPlayerVehicle()
  if not playerVeh then
    return false
  end

  local spots = getSiteParkingSpots()
  if not spots or #spots < 1 then
    ui_message('Auction spots missing in auction.sites.json', 8, 'Used Auction', 'warning')
    return false
  end

  setAuctionRunningTriggerState()
  auctionState.phase = 'starting'

  runFadedTransition(function()
    auctionState.returnTransform = {
      pos = playerVeh:getPosition(),
      rot = quat(playerVeh:getRefNodeRotation())
    }

    local layout = buildSiteLayout(spots)
    auctionState.siteLayout = layout
    auctionState.auctionSpot = layout.playerSpot
    auctionState.travelSpot = layout.playerSpot

    if not layout.playerSpot then
      ui_message('Missing spot tag: auctionPlayerStart.', 8, 'Used Auction', 'warning')
      resetAuction(false)
      return
    end
    if #layout.spawnSpots < 1 then
      ui_message('Missing spot tag: auctionSpawn.', 8, 'Used Auction', 'warning')
      resetAuction(false)
      return
    end
    if not layout.despawnSpot then
      ui_message('Missing spot tag: auctionDespawn.', 8, 'Used Auction', 'warning')
      resetAuction(false)
      return
    end

    teleportVehicleToSpot(playerVeh, auctionState.auctionSpot)

    auctionState.lots = prepareLots(layout.spawnSpots, layout.blockSpots, DEFAULT_LOT_COUNT)
    auctionState.activeLotIndex = 0
    auctionState.awaitingFinalExit = false

    local started = startNextLotAfter(0)
    if not started then
      setAuctionComplete()
      ui_message('Auction failed to start (no spawnable lots).', 7, 'Used Auction', 'warning')
      return
    end

    auctionState.phase = 'bidding'

    ui_message('Auction started. Vehicles now spawn sequentially: next lot drives in while previous exits.', 8, 'Used Auction', 'info')
  end)

  return true
end

local function distributePurchasedVehiclesAround(pos, baseRot)
  local returnSpots = ((auctionState.siteLayout or {}).returnSpots) or {}

  local placed = 0
  for _, inventoryId in ipairs(auctionState.purchasedInventoryIds) do
    local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
    local veh = vehId and getObjectByID(vehId)
    if not veh then
      local spawnedVeh = career_modules_inventory.spawnVehicle(inventoryId)
      if spawnedVeh then
        vehId = spawnedVeh:getID()
        veh = spawnedVeh
      end
    end

    if veh then
      placed = placed + 1
      local returnSpot = returnSpots[placed]
      if returnSpot and returnSpot.moveResetVehicleTo then
        returnSpot:moveResetVehicleTo(veh:getID(), nil, nil, nil, nil, true)
      else
        local row = math.floor((placed - 1) / 2)
        local side = ((placed - 1) % 2 == 0) and 1 or -1
        local offset = vec3((6 + row * 4) * side, -8 - (row * 4), 0)
        local worldOffset = baseRot * offset
        local target = pos + worldOffset
        local rot = quat(0, 0, 1, 0) * baseRot
        veh:setPosRot(target.x, target.y, target.z + 0.5, rot.x, rot.y, rot.z, rot.w)
      end
      stopVehicleAI(veh)
    end
  end
end

local function exitAuctionArea()
  if auctionState.transitionActive then
    return false
  end

  local playerVeh = getPlayerVehicle()
  if not playerVeh or not auctionState.returnTransform then
    return false
  end

  runFadedTransition(function()
    local spot = {
      pos = auctionState.returnTransform.pos,
      rot = auctionState.returnTransform.rot
    }

    teleportVehicleToSpot(playerVeh, spot)
    distributePurchasedVehiclesAround(auctionState.returnTransform.pos, auctionState.returnTransform.rot)

    if career_saveSystem then
      career_saveSystem.saveCurrent()
    end

    resetAuction(true)
    auctionState.entryCooldownUntil = os.clock() + ENTRY_RETRIGGER_COOLDOWN
    ui_message('Returned from auction.', 5, 'Used Auction', 'info')
  end)

  return true
end

local function onBeamNGTrigger(data)
  if not career_career.isActive() then return end

  local playerVehId = be:getPlayerVehicleID(0)
  if not playerVehId or data.subjectID ~= playerVehId then
    return
  end

  if data.event ~= 'enter' then
    return
  end

  if data.triggerName and data.triggerName:find(ENTRY_TRIGGER) then
    if os.clock() < (auctionState.entryCooldownUntil or 0) then
      return
    end

    if auctionState.phase == 'idle' then
      startAuctionImmediate()
    end
    return
  end

  if data.triggerName and data.triggerName:find(EXIT_TRIGGER) then
    if auctionState.phase ~= 'idle' then
      exitAuctionArea()
    end
  end
end

local function onUpdate()
  if auctionState.phase ~= 'bidding' then
    return
  end

  local now = os.clock()

  local function refreshMotionProgress(lot, veh, tNow)
    if not veh then return end
    local currentPos = vec3(veh:getPosition())
    local prevPos = lot.lastMotionPos
    if not prevPos then
      lot.lastMotionPos = currentPos
      lot.lastMotionAt = tNow
      return
    end

    if (currentPos - prevPos):length() >= LOT_PROGRESS_DISTANCE then
      lot.lastMotionPos = currentPos
      lot.lastMotionAt = tNow
    end
  end

  local function hasLiveTransitionLots()
    for _, checkLot in ipairs(auctionState.lots or {}) do
      if checkLot.state == 'approaching' or checkLot.state == 'active' or checkLot.state == 'exiting' then
        return true
      end
    end
    return false
  end

  for _, lot in ipairs(auctionState.lots or {}) do
    if lot.state == 'approaching' then
      local lotVeh = lot.vehId and getObjectByID(lot.vehId)
      refreshMotionProgress(lot, lotVeh, now)
      local arrived = false
      if lotVeh then
        local blockSpot = lot.blockSpot or lot.spawnSpot
        if blockSpot then
          arrived = (lotVeh:getPosition() - vec3(blockSpot.pos)):length() <= LOT_ARRIVE_DISTANCE
        end
      end
      if arrived then
        beginLotBidding(lot, false)
      elseif (now - (lot.lastMotionAt or now) >= LOT_STUCK_TIMEOUT) then
        beginLotBidding(lot, true)
      end
    elseif lot.state == 'exiting' then
      local lotVeh = lot.vehId and getObjectByID(lot.vehId)
      refreshMotionProgress(lot, lotVeh, now)
      local done = false
      if not lotVeh then
        done = true
      elseif auctionState.siteLayout and auctionState.siteLayout.despawnSpot then
        local dist = (lotVeh:getPosition() - vec3(auctionState.siteLayout.despawnSpot.pos)):length()
        done = dist <= LOT_EXIT_DESPAWN_DISTANCE
      end

      if done or (now - (lot.lastMotionAt or now) >= LOT_STUCK_TIMEOUT) then
        if lotVeh then
          despawnLotVehicle(lot)
        end
        lot.state = 'finished'
        lot.driveState = 'done'
      end
    end
  end

  if auctionState.awaitingFinalExit and not hasLiveTransitionLots() then
    setAuctionComplete()
    return
  end

  local lot = auctionState.lots[auctionState.activeLotIndex]
  if not lot or lot.state ~= 'active' then
    return
  end

  if now >= lot.endTime then
    finishCurrentLot()
    return
  end

  showLiveAuctionStatus(false)

  if now >= auctionState.nextPlayerBidCheckAt then
    auctionState.nextPlayerBidCheckAt = now + PLAYER_BID_CHECK_INTERVAL
  end

  if now >= auctionState.nextNpcBidAt then
    local nextBid = lot.currentBid + lot.minStep
    if nextBid <= lot.npcMaxBid then
      if lot.highestBidder == 'player' then
        if math.random() < 0.65 then
          lot.currentBid = nextBid
          lot.highestBidder = 'npc'
          maybeExtendLotTimer(lot, 'NPC')
        end
      else
        if math.random() < 0.35 then
          lot.currentBid = nextBid
          lot.highestBidder = 'npc'
          maybeExtendLotTimer(lot, 'NPC')
        end
      end
    end

    auctionState.nextNpcBidAt = now + (NPC_BID_COOLDOWN_MIN + math.random() * (NPC_BID_COOLDOWN_MAX - NPC_BID_COOLDOWN_MIN))
  end
end

local function onCareerActivated()
  setIdleTriggerState()
end

local function onCareerDeactivatedWhileLevelLoaded()
  resetAuction(false)
end

M.onBeamNGTrigger = onBeamNGTrigger
M.onUpdate = onUpdate
M.onCareerActivated = onCareerActivated
M.onCareerDeactivatedWhileLevelLoaded = onCareerDeactivatedWhileLevelLoaded
M.exitAuctionArea = exitAuctionArea
M.requestAuctionState = requestAuctionState
M.startAuction = startAuction
M.cancelTravelPrompt = cancelTravelPrompt
M.placeBid = placeBid
M.passCurrentLot = passCurrentLot
M.closeMenu = closeMenu

return M
