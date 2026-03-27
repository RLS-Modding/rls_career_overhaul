local M = {}

M.dependencies = {
  'career_career',
  'career_modules_inventory',
  'career_modules_garageManager',
  'career_modules_marketplace',
  'career_modules_payment',
  'career_modules_valueCalculator',
  'career_saveSystem',
  'gameplay_sites_sitesManager',
  'gameplay_traffic',
  'util_configListGenerator',
  'overhaul_musicPlayer'
}

local constants = {
  ENTRY_TRIGGER = 'usedCarAuctionEntry',
  EXIT_TRIGGER = 'usedCarAuctionExit',
  AUCTION_SITES_NAME = 'auction',

  LOT_DURATION = 30,
  NPC_BID_COOLDOWN_MIN = 2.0,
  NPC_BID_COOLDOWN_MAX = 4.0,
  PLAYER_BID_CHECK_INTERVAL = 0.6,
  PLAYER_BID_DISTANCE = 18,
  FADE_DURATION = 0.35,
  ENTRY_RETRIGGER_COOLDOWN = 4.0,
  LIVE_STATUS_INTERVAL = 1.0,
  LOT_ARRIVE_DISTANCE = 2.5,
  LOT_ARRIVE_SPEED_MPS = 1.4,
  LOT_APPROACH_BRAKE_DISTANCE = 10.0,
  LOT_APPROACH_SLOW_SPEED_MPS = 1.8,
  LOT_APPROACH_CONTROL_INTERVAL = 0.2,
  LOT_EXIT_DESPAWN_DISTANCE = 5.0,
  AI_MAX_SPEED_MPS = 4.4352, -- 5 mph
  LOAD_EJECT_DISTANCE = 180,
  LOT_STUCK_TIMEOUT = 5.0,
  LOT_PROGRESS_DISTANCE = 0.35,
  ANTI_SNIPE_WINDOW = 10.0,
  ANTI_SNIPE_EXTEND = 8.0,
  VEHICLE_SWITCH_REJECT_WARN_COOLDOWN = 2.5,
  VEHICLE_SWITCH_REVERT_DELAY = 0.05,
  DEFAULT_LOT_COUNT = 8,
  NPC_PERSONA_COUNT = 3,
  NPC_MAX_BID_MULT_MIN = 0.55,
  NPC_MAX_BID_MULT_MAX = 1.50,
  NPC_BID_INCREMENTS = {250, 500, 1000, 5000},
  LOT_WIN_EMITTER_DURATION = 2.0,
  AUCTION_WIN_EMITTERS_GROUP = 'auctionEmitters',
  AUCTION_ACTIVE_ASSETS_GROUP = 'auctionAssetsOn',
  AUCTION_MUSIC_EMITTER_NAME = 'SFXEmitter_2',
  AUCTION_ENTRY_PAYMENT_SFX_EVENT = 'event:>UI>Career>Buy_01',
  AUCTION_ENTRY_FEE = 1000,
  AUCTION_SETTINGS_SAVE_FILE = 'usedCarAuctionSettings.json',
  BID_ACCEPTED_SFX_EVENT = 'event:>UI>Career>Buy_02',
  LOT_WIN_CELEBRATION_SFX_EVENT = 'event:>UI>Missions>End_Gold',
  AUCTION_POI_ID = 'usedCarAuctionEntrance',
  AUCTION_POI_LEVEL = 'west_coast_usa',
  AUCTION_POI_ICON = 'poi_fasttravel_round_orange_green',
  AUCTION_EXIT_MARKER_NAME = 'usedCarAuctionExitMarker',
  AUCTION_EXIT_MARKER_SHAPE = 'art/shapes/interface/checkpoint_marker.dae',
  AUCTION_EXIT_MARKER_SCALE = 2.2,
  AUCTION_EXIT_MARKER_COLOR = '1.00 0.10 0.10 0.95',
  AUCTION_EXIT_MARKER_Z_OFFSET = -0.8,
  AUCTION_ENTRY_LOADING_TAG = 'usedCarAuctionEntry'
}

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
  simTime = 0,
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
  switchWarnCooldownUntil = 0,
  lastValidPlayerVehId = nil,
  entryPromptActive = false,
  uiOpen = false,
  awaitingFinalExit = false,
  npcPersonas = {},
  winEmitterPulseToken = 0,
  musicEnabled = true,
  bidHint = nil,
  bidHintUntil = 0
}

local usedConfigKeys = {}
local partsValueCache = {}
local badConfigLogOnce = {}
local stopVehicleAI
local setLotVehicleDriveLock
local startAuctionImmediate

local function getAuctionTime()
  return auctionState.simTime or 0
end

local function advanceAuctionTime(dtSim)
  local delta = tonumber(dtSim) or 0
  if delta < 0 then
    delta = 0
  end
  auctionState.simTime = (auctionState.simTime or 0) + delta
  return auctionState.simTime
end

local function getAuctionSettingsPaths(currentSavePath)
  if not currentSavePath and career_saveSystem and career_saveSystem.getCurrentSaveSlot then
    local _, savePath = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = savePath
  end
  if not currentSavePath then
    return nil, nil
  end

  local dirPath = currentSavePath .. '/career/rls_career'
  return dirPath, dirPath .. '/' .. constants.AUCTION_SETTINGS_SAVE_FILE
end

local function saveAuctionSettings(currentSavePath)
  if not (FS and career_saveSystem and career_saveSystem.jsonWriteFileSafe) then
    return false
  end

  local dirPath, filePath = getAuctionSettingsPaths(currentSavePath)
  if not filePath then
    return false
  end

  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  career_saveSystem.jsonWriteFileSafe(filePath, {
    musicEnabled = auctionState.musicEnabled ~= false
  }, true)
  return true
end

local function loadAuctionSettings()
  auctionState.musicEnabled = true
  if not (career_career and career_career.isActive and career_career.isActive()) then
    return false
  end

  local _, filePath = getAuctionSettingsPaths()
  if not filePath then
    return false
  end

  local data = jsonReadFile(filePath)
  if type(data) ~= 'table' then
    return false
  end

  if data.musicEnabled ~= nil then
    auctionState.musicEnabled = data.musicEnabled and true or false
  end
  return true
end

local function deepCopy(src)
  if type(src) ~= 'table' then return src end
  local out = {}
  for k, v in pairs(src) do
    out[k] = deepCopy(v)
  end
  return out
end

local function getFilterLists(filter)
  if type(filter) ~= 'table' then
    return {}, {}
  end

  local whiteList = filter.whiteList or filter.whitelist or filter.white_list or {}
  local blackList = filter.blackList or filter.blacklist or filter.black_list or {}
  return whiteList, blackList
end

local function normalizeFilterDefinition(filter)
  local normalized = deepCopy(type(filter) == 'table' and filter or {})
  local whiteList, blackList = getFilterLists(normalized)
  normalized.whiteList = deepCopy(whiteList or {})
  normalized.blackList = deepCopy(blackList or {})
  normalized.whitelist = nil
  normalized.white_list = nil
  normalized.blacklist = nil
  normalized.black_list = nil
  return normalized
end

local function getSubFilterBody(subFilter)
  if type(subFilter) ~= 'table' then
    return {}
  end
  if type(subFilter.filter) == 'table' then
    return subFilter.filter
  end
  return subFilter
end

local function mergeFilter(baseFilter, subFilter)
  local merged = normalizeFilterDefinition(baseFilter)
  local normalizedSubFilter = normalizeFilterDefinition(getSubFilterBody(subFilter))

  for k, v in pairs(normalizedSubFilter.whiteList or {}) do
    merged.whiteList[k] = deepCopy(v)
  end
  for k, v in pairs(normalizedSubFilter.blackList or {}) do
    merged.blackList[k] = deepCopy(v)
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
  local baseFilter = normalizeFilterDefinition(cfg.filter or {})
  local subFilters = cfg.subFilters or {}

  local weighted = {}
  if #subFilters == 0 then
    table.insert(weighted, {prob = 1, filter = deepCopy(baseFilter)})
    return weighted
  end

  for _, sf in ipairs(subFilters) do
    local sfBody = getSubFilterBody(sf)
    local p = tonumber(sf.probability) or tonumber(sf._probability) or tonumber(sfBody.probability) or tonumber(sfBody._probability) or 1
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

local function clearAuctionExitMarker()
  local marker = scenetree.findObject(constants.AUCTION_EXIT_MARKER_NAME)
  if not marker then
    return
  end

  if editor and editor.onRemoveSceneTreeObjects and marker.getID then
    pcall(function() editor.onRemoveSceneTreeObjects({marker:getID()}) end)
  end
  pcall(function() marker:delete() end)
end

local function setIdleTriggerState()
  setTriggerHidden(constants.ENTRY_TRIGGER, false)
  setTriggerHidden(constants.EXIT_TRIGGER, true)
end

local function setAuctionRunningTriggerState()
  setTriggerHidden(constants.ENTRY_TRIGGER, true)
  setTriggerHidden(constants.EXIT_TRIGGER, false)
end

local function openMenu()
  auctionState.uiOpen = true
  pcall(function() guihooks.trigger('UsedAuctionShow') end)
end

local function closeAuctionOverlayUi()
  auctionState.uiOpen = false
  pcall(function() guihooks.trigger('UsedAuctionHide') end)
end

local function startFadeSafe()
  if ui_fadeScreen and ui_fadeScreen.start then
    pcall(function() ui_fadeScreen.start(constants.FADE_DURATION) end)
  end
end

local function stopFadeSafe()
  if ui_fadeScreen and ui_fadeScreen.stop then
    pcall(function() ui_fadeScreen.stop(constants.FADE_DURATION) end)
  end
end

local function exitAuctionEntryLoadingScreen()
  if not core_gamestate or not core_gamestate.requestExitLoadingScreen then
    return
  end
  if core_gamestate.getLoadingStatus and not core_gamestate.getLoadingStatus(constants.AUCTION_ENTRY_LOADING_TAG) then
    return
  end
  pcall(function()
    core_gamestate.requestExitLoadingScreen(constants.AUCTION_ENTRY_LOADING_TAG)
  end)
end

local function runFadedTransition(workFn)
  if auctionState.transitionActive then
    return
  end

  auctionState.transitionActive = true
  core_jobsystem.create(function(job)
    startFadeSafe()
    job.sleep(constants.FADE_DURATION)

    local ok, err = pcall(workFn)

    stopFadeSafe()
    exitAuctionEntryLoadingScreen()
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

local function playUiSound(eventName)
  if not eventName or eventName == '' then return end
  if Engine and Engine.Audio and Engine.Audio.playOnce then
    pcall(function()
      Engine.Audio.playOnce('AudioGui', eventName)
    end)
  end
end

local function playBidAcceptedSound()
  playUiSound(constants.BID_ACCEPTED_SFX_EVENT)
end

local function playLotWinCelebrationSound()
  playUiSound(constants.LOT_WIN_CELEBRATION_SFX_EVENT)
end

local function getRandomNpcBidCooldown()
  return constants.NPC_BID_COOLDOWN_MIN + math.random() * (constants.NPC_BID_COOLDOWN_MAX - constants.NPC_BID_COOLDOWN_MIN)
end

local function scheduleNextNpcBid(baseTime)
  auctionState.nextNpcBidAt = (tonumber(baseTime) or getAuctionTime()) + getRandomNpcBidCooldown()
end

local function resolveSceneRefToObject(ref)
  local refType = type(ref)
  if refType == 'userdata' then return ref end
  if refType == 'number' then return scenetree.findObjectById(ref) end
  if refType == 'string' then return scenetree.findObject(ref) end
  return nil
end

local function listChildrenSafe(obj)
  if not obj or not obj.getObjects then
    return {}
  end

  local ok, refs = pcall(function()
    return obj:getObjects()
  end)
  if not ok or type(refs) ~= 'table' then
    return {}
  end

  local out = {}
  for _, ref in ipairs(refs) do
    local child = resolveSceneRefToObject(ref)
    if child then
      table.insert(out, child)
    end
  end
  return out
end

local function setEmitterObjectEnabled(obj, enabled)
  if not obj then return end
  local boolEnabled = enabled and true or false
  local numericEnabled = boolEnabled and 1 or 0
  local textEnabled = boolEnabled and '1' or '0'

  if obj.setEnabled then
    pcall(function() obj:setEnabled(boolEnabled) end)
  end
  if obj.setActive then
    pcall(function() obj:setActive(numericEnabled) end)
  end
  if obj.setField then
    pcall(function() obj:setField('enabled', 0, textEnabled) end)
    pcall(function() obj:setField('active', 0, textEnabled) end)
    pcall(function() obj:setField('isEnabled', 0, textEnabled) end)
  end
  if obj.setHidden then
    pcall(function() obj:setHidden(not boolEnabled) end)
  end
end

local function getSceneObjectName(obj)
  if not obj or not obj.getName then
    return nil
  end
  local ok, name = pcall(function() return obj:getName() end)
  if ok then
    return name
  end
  return nil
end

local function setAuctionActiveAssetObjectEnabled(obj, enabled, musicEnabled)
  if not obj then return end

  local objName = getSceneObjectName(obj)
  local isAuctionMusicEmitter = objName == constants.AUCTION_MUSIC_EMITTER_NAME
  local effectiveEnabled = enabled and true or false
  if isAuctionMusicEmitter and (not musicEnabled) then
    effectiveEnabled = false
  end

  setEmitterObjectEnabled(obj, effectiveEnabled)

  if effectiveEnabled and obj.play and not isAuctionMusicEmitter then
    local played = pcall(function() obj:play() end)
    if not played then
      pcall(function() obj:play(-1) end)
    end
  elseif (not effectiveEnabled) and obj.stop then
    local stopped = pcall(function() obj:stop() end)
    if not stopped then
      pcall(function() obj:stop(-1) end)
    end
  end
end

local function setAuctionWinEmittersEnabled(enabled)
  local root = scenetree.findObject(constants.AUCTION_WIN_EMITTERS_GROUP)
  if not root then
    return false
  end

  local visited = {}
  local function applyRecursive(obj)
    if not obj then return end
    local id = obj.getID and obj:getID() or tostring(obj)
    if visited[id] then return end
    visited[id] = true

    setEmitterObjectEnabled(obj, enabled)
    for _, child in ipairs(listChildrenSafe(obj)) do
      applyRecursive(child)
    end
  end

  applyRecursive(root)
  return true
end

local function setAuctionActiveAssetsEnabled(enabled)
  local root = scenetree.findObject(constants.AUCTION_ACTIVE_ASSETS_GROUP)
  if not root then
    return false
  end
  local musicEnabled = auctionState.musicEnabled ~= false

  local visited = {}
  local function applyRecursive(obj)
    if not obj then return end
    local id = obj.getID and obj:getID() or tostring(obj)
    if visited[id] then return end
    visited[id] = true

    setAuctionActiveAssetObjectEnabled(obj, enabled, musicEnabled)
    for _, child in ipairs(listChildrenSafe(obj)) do
      applyRecursive(child)
    end
  end

  applyRecursive(root)
  return true
end

local function hardDisableAuctionAudioVisuals()
  setAuctionWinEmittersEnabled(false)
  setAuctionActiveAssetsEnabled(false)
  clearAuctionExitMarker()
end

local function triggerAuctionWinEmitters(duration)
  local pulseDuration = tonumber(duration) or constants.LOT_WIN_EMITTER_DURATION
  if pulseDuration <= 0 then return end
  if not (core_jobsystem and core_jobsystem.create) then return end

  auctionState.winEmitterPulseToken = (auctionState.winEmitterPulseToken or 0) + 1
  local token = auctionState.winEmitterPulseToken

  setAuctionWinEmittersEnabled(true)
  core_jobsystem.create(function(job)
    job.sleep(pulseDuration)
    if token ~= (auctionState.winEmitterPulseToken or 0) then
      return
    end
    setAuctionWinEmittersEnabled(false)
  end)
end

local function isSpotFree(spot)
  if not spot then return false end
  if spot.vehicle then return false end
  if spot.hasAnyVehicles then
    local ok, hasAny = pcall(function() return spot:hasAnyVehicles() end)
    if ok and hasAny then
      return false
    end
  end
  return true
end

local function removeSpotFromList(spots, spotToRemove)
  if not spots or not spotToRemove then return false end
  for i, spot in ipairs(spots) do
    if spot == spotToRemove then
      table.remove(spots, i)
      return true
    end
  end
  return false
end

local function getBestReturnSpotForVehicle(vehId, candidateSpots)
  if not vehId or type(candidateSpots) ~= 'table' or #candidateSpots == 0 then
    return nil
  end

  if gameplay_sites_sitesManager and gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList then
    local ok, bestSpot = pcall(function()
      return gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehId, candidateSpots)
    end)
    if ok and bestSpot then
      return bestSpot
    end
  end

  return candidateSpots[1]
end

local function despawnLotVehicle(lot)
  if not lot then return end
  if lot.wonInventoryId then
    local veh = lot.vehId and getObjectByID(lot.vehId)
    if veh then
      -- Won vehicles stay loaded; park them at return spots for instant availability.
      local returnSpots = ((auctionState.siteLayout or {}).returnSpots) or {}
      local freeSpots = {}
      for _, spot in ipairs(returnSpots) do
        if isSpotFree(spot) then
          table.insert(freeSpots, spot)
        end
      end
      local returnSpot = getBestReturnSpotForVehicle(veh:getID(), freeSpots)
      if returnSpot and returnSpot.moveResetVehicleTo then
        pcall(function() returnSpot:moveResetVehicleTo(veh:getID(), nil, nil, nil, nil, true) end)
      end
      if gameplay_traffic then
        pcall(function() gameplay_traffic.removeTraffic(veh:getID()) end)
      end
      setLotVehicleDriveLock(veh, 'staged')
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

local function getAuctionEntryFee()
  return tonumber(constants.AUCTION_ENTRY_FEE) or 0
end

local function canAffordAuctionEntry()
  local fee = getAuctionEntryFee()
  if fee <= 0 then
    return true
  end
  return canAfford(fee)
end

local function payAuctionEntryFee()
  local fee = getAuctionEntryFee()
  if fee <= 0 then
    return true
  end

  return payForVehicle(fee, string.format('Used Auction Entry ($%d)', fee))
end

local function getPlayerVehicle()
  return be:getPlayerVehicle(0)
end

local function isAuctionLotVehicleId(vehId)
  if not vehId then return false end
  for _, lot in ipairs(auctionState.lots or {}) do
    if lot and lot.vehId == vehId then
      return true
    end
  end
  return false
end

local function setVehicleFreezeSafe(veh, shouldFreeze)
  if not veh then return end
  local freezeValue = shouldFreeze and true or false
  if core_vehicleBridge and core_vehicleBridge.executeAction then
    pcall(function() core_vehicleBridge.executeAction(veh, 'setFreeze', freezeValue) end)
  else
    veh:queueLuaCommand(string.format('controller.setFreeze(%d)', shouldFreeze and 1 or 0))
  end
end

setLotVehicleDriveLock = function(veh, mode)
  if not veh then return end

  -- Never allow driving auction lot vehicles while auction is active.
  veh.playerUsable = (mode == 'released')

  if mode == 'transit' then
    setVehicleFreezeSafe(veh, false)
    veh:queueLuaCommand('electrics.setIgnitionLevel(1)')
    veh:queueLuaCommand('input.event("brake", 0, 1)')
    veh:queueLuaCommand('input.event("parkingbrake", 0, 1)')
    return
  end

  if mode == 'released' then
    setVehicleFreezeSafe(veh, false)
    veh:queueLuaCommand('ai.setMode("stop")')
    veh:queueLuaCommand('electrics.setIgnitionLevel(0)')
    return
  end

  -- 'bidding' and 'staged': dealership-like freeze lock.
  stopVehicleAI(veh)
  setVehicleFreezeSafe(veh, true)
end

local function getSiteParkingSpots()
  local sitePath = gameplay_sites_sitesManager.getCurrentLevelSitesFileByName(constants.AUCTION_SITES_NAME)
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
    playerExitSpot = nil,
    spawnSpots = {},
    blockSpots = {},
    pathInSpots = {},
    pathOutSpots = {},
    despawnSpot = nil,
    returnSpots = {}
  }

  layout.playerSpot = firstSpotWithTag(spots, {'auctionPlayerStart'})
  layout.playerExitSpot = firstSpotWithTag(spots, {'auctionPlayerExit'})
  layout.spawnSpots = collectTaggedSpots(spots, 'auctionSpawn')
  layout.blockSpots = collectTaggedSpots(spots, 'auctionBlock')

  layout.pathInSpots = collectTaggedSpots(spots, 'auctionPathIn')
  layout.pathOutSpots = collectTaggedSpots(spots, 'auctionPathOut')
  layout.despawnSpot = firstSpotWithTag(spots, {'auctionDespawn'})

  layout.returnSpots = collectTaggedSpots(spots, 'auctionReturn')

  return layout
end

local function buildSpotFromTrigger(triggerName)
  local trigger = scenetree.findObject(triggerName)
  if not trigger then
    return nil
  end

  local posOk, pos = pcall(function() return trigger:getPosition() end)
  local rotOk, rot = pcall(function() return trigger:getRotation() end)
  if not posOk or not pos or not rotOk or not rot then
    return nil
  end

  return {
    pos = vec3(pos),
    -- teleportVehicleToSpot prepends a 180 deg Z correction; pre-apply it so the
    -- final facing matches the trigger rotation exactly.
    rot = quat(0, 0, 1, 0) * quat(rot)
  }
end

local function getPlayerExitSpot(layout, warnOnFallback)
  if layout and layout.playerExitSpot then
    return layout.playerExitSpot
  end

  local fallbackSpot = buildSpotFromTrigger(constants.ENTRY_TRIGGER)
  if not fallbackSpot then
    return nil
  end

  if warnOnFallback then
    log('W', 'usedCarAuction', 'Missing spot tag: auctionPlayerExit. Falling back to entry trigger transform.')
  end

  if layout then
    layout.playerExitSpot = fallbackSpot
  end
  return fallbackSpot
end

local function ensureAuctionExitMarker(layout)
  clearAuctionExitMarker()

  local markerPos = nil
  local exitTrigger = scenetree.findObject(constants.EXIT_TRIGGER)
  if exitTrigger then
    local ok, pos = pcall(function() return exitTrigger:getPosition() end)
    if ok and pos then
      markerPos = vec3(pos)
    end
  end

  if not markerPos then
    local exitSpot = getPlayerExitSpot(layout, false)
    if exitSpot and exitSpot.pos then
      markerPos = vec3(exitSpot.pos)
    end
  end

  if not markerPos then
    return false
  end

  local marker = createObject('TSStatic')
  marker:setField('shapeName', 0, constants.AUCTION_EXIT_MARKER_SHAPE)
  marker:setPosition(markerPos + vec3(0, 0, constants.AUCTION_EXIT_MARKER_Z_OFFSET))
  marker.scale = vec3(constants.AUCTION_EXIT_MARKER_SCALE, constants.AUCTION_EXIT_MARKER_SCALE, constants.AUCTION_EXIT_MARKER_SCALE)
  marker:setField('rotation', 0, '1 0 0 0')
  marker.useInstanceRenderData = true
  marker:setField('instanceColor', 0, constants.AUCTION_EXIT_MARKER_COLOR)
  marker:setField('collisionType', 0, 'Collision Mesh')
  marker:setField('decalType', 0, 'Collision Mesh')
  marker:setField('allowPlayerStep', 0, '1')
  marker:setField('canSave', 0, '0')
  marker:setField('canSaveDynamicFields', 0, '1')
  marker.canSave = false
  marker:registerObject(constants.AUCTION_EXIT_MARKER_NAME)
  if scenetree and scenetree.MissionGroup then
    scenetree.MissionGroup:addObject(marker)
  end

  return true
end

local function getAuctionEntrancePos()
  local trigger = scenetree.findObject(constants.ENTRY_TRIGGER)
  if trigger then
    local ok, pos = pcall(function() return trigger:getPosition() end)
    if ok and pos then
      return vec3(pos)
    end
  end

  local spots = getSiteParkingSpots()
  if not spots or #spots < 1 then
    return nil
  end

  local layout = buildSiteLayout(spots)
  local fallbackSpot = getPlayerExitSpot(layout, false)
  if fallbackSpot and fallbackSpot.pos then
    return vec3(fallbackSpot.pos)
  end
  return nil
end

local function formatAuctionEntrancePoi(levelIdentifier)
  if levelIdentifier ~= constants.AUCTION_POI_LEVEL then
    return nil
  end

  local pos = getAuctionEntrancePos()
  if not pos then
    return nil
  end

  return {
    id = constants.AUCTION_POI_ID,
    data = {
      type = 'travel',
      facility = {}
    },
    markerInfo = {
      bigmapMarker = {
        pos = pos,
        icon = constants.AUCTION_POI_ICON,
        cardIcon = 'carDealer',
        name = 'Used Car Auction',
        description = 'Entrance to the auction vault.'
      }
    }
  }
end

local function teleportVehicleToSpot(veh, spot)
  if not veh or not spot then return false end

  local isPlayerVeh = veh:getID() == be:getPlayerVehicleID(0)
  local function applyWalkingFacingFromQuat(rotQ)
    if not isPlayerVeh then return end
    if not (gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() and gameplay_walk.setRot) then
      return
    end
    local front = rotQ * vec3(0, 1, 0)
    gameplay_walk.setRot(front, vec3(0, 0, 1))
  end

  if isPlayerVeh and spot.moveResetVehicleTo then
    local ok = pcall(function()
      local options = {skipVehicleIntersectionCheck = true}
      spot:moveResetVehicleTo(veh:getID(), nil, false, nil, nil, true, false, nil, options)
    end)
    if ok then
      if core_camera and core_camera.resetCamera then
        pcall(function() core_camera.resetCamera(0) end)
      end
      applyWalkingFacingFromQuat(quat(spot.rot))
      veh:queueLuaCommand('electrics.setIgnitionLevel(0)')
      return true
    end
  end

  local pos = vec3(spot.pos)
  local rot = quat(0, 0, 1, 0) * quat(spot.rot)
  veh:setPosRot(pos.x, pos.y, pos.z + 0.5, rot.x, rot.y, rot.z, rot.w)
  applyWalkingFacingFromQuat(rot)
  veh:queueLuaCommand('electrics.setIgnitionLevel(0)')
  return true
end

stopVehicleAI = function(veh)
  if not veh then return end
  veh:queueLuaCommand('ai.setMode("stop")')
  veh:queueLuaCommand('electrics.setIgnitionLevel(0)')
  veh:queueLuaCommand('electrics.setLightsState(1)')
end

local function closeVehicleOpenables(veh)
  if not veh then return end
  veh:queueLuaCommand([[
    for _, ctrl in pairs(controller.getControllersByType("advancedCouplerControl")) do
      ctrl.tryAttachGroupImpulse()
    end
  ]])
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
  veh:queueLuaCommand(string.format('ai.setSpeed(%.4f)', constants.AI_MAX_SPEED_MPS))
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
  veh:queueLuaCommand(string.format('ai.setSpeed(%.4f)', constants.AI_MAX_SPEED_MPS))
  return true
end

local function applyApproachStopControl(lot, veh, distToBlock, speed, now)
  if not lot or not veh or not distToBlock then return end
  if distToBlock > constants.LOT_APPROACH_BRAKE_DISTANCE then return end
  if now < (lot.nextApproachControlAt or 0) then return end
  lot.nextApproachControlAt = now + constants.LOT_APPROACH_CONTROL_INTERVAL

  -- Quarry-style settle: require low speed at the target and actively brake when close.
  if distToBlock <= constants.LOT_ARRIVE_DISTANCE and speed > constants.LOT_ARRIVE_SPEED_MPS then
    veh:queueLuaCommand('input.event("throttle", 0, 1)')
    veh:queueLuaCommand('input.event("brake", 1, 1)')
    veh:queueLuaCommand('input.event("parkingbrake", 1, 1)')
    return
  end

  -- As we approach the block spot, keep AI path-following but force a much lower approach speed.
  veh:queueLuaCommand('input.event("brake", 0, 1)')
  veh:queueLuaCommand('input.event("parkingbrake", 0, 1)')
  veh:queueLuaCommand('ai.setSpeedMode("set")')
  veh:queueLuaCommand(string.format('ai.setSpeed(%.4f)', constants.LOT_APPROACH_SLOW_SPEED_MPS))
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

local function getLotMileageMeters(lot)
  local mileageMiles = tonumber(lot and lot.mileage) or 0
  return math.max(0, math.floor(mileageMiles * 1609.344))
end

local function getCurrentYear()
  return tonumber(os.date('%Y')) or 2025
end

local function isRangeParams(parameters)
  return type(parameters) == 'table' and (parameters.min ~= nil or parameters.max ~= nil)
end

local function normalizeToken(value)
  if value == nil then
    return ''
  end
  return tostring(value):lower():gsub('[^%w]', '')
end

local filterFieldAliases = {
  bodytype = { 'Body Type', 'BodyType', 'Body Style', 'BodyStyle' },
  configtype = { 'Config Type', 'ConfigType' },
  type = { 'Type', 'Vehicle Type', 'VehicleType' },
  brand = { 'Brand', 'Make' },
  years = { 'Years', 'Year' }
}

local function getFilterFieldCandidates(fieldName)
  local candidates = {}
  local seen = {}

  local function addCandidate(value)
    if value == nil then
      return
    end
    local key = tostring(value)
    if key == '' or seen[key] then
      return
    end
    seen[key] = true
    table.insert(candidates, key)
  end

  addCandidate(fieldName)
  local aliases = filterFieldAliases[normalizeToken(fieldName)]
  if type(aliases) == 'table' then
    for _, alias in ipairs(aliases) do
      addCandidate(alias)
    end
  end

  return candidates
end

local function getLooseTableField(source, fieldName)
  if type(source) ~= 'table' then
    return nil
  end

  local value = source[fieldName]
  if value ~= nil then
    return value
  end

  local wantedKey = normalizeToken(fieldName)
  for key, item in pairs(source) do
    if normalizeToken(key) == wantedKey then
      return item
    end
  end

  return nil
end

local function getVehicleFieldValue(vehicleInfo, fieldName)
  if type(vehicleInfo) ~= 'table' then return nil end

  local candidates = getFilterFieldCandidates(fieldName)
  for _, candidate in ipairs(candidates) do
    local value = getLooseTableField(vehicleInfo, candidate)
    if value ~= nil then
      return value
    end
  end

  if type(vehicleInfo.aggregates) == 'table' then
    for _, candidate in ipairs(candidates) do
      local value = getLooseTableField(vehicleInfo.aggregates, candidate)
      if value ~= nil then
        return value
      end
    end
  end

  return nil
end

local function getVehicleYearRange(vehicleInfo)
  local years = getVehicleFieldValue(vehicleInfo, 'Years')
  if type(years) == 'number' then
    return years, years
  end
  if type(years) ~= 'table' then
    return nil, nil
  end

  local minYear = tonumber(years.min) or tonumber(years[1])
  local maxYear = tonumber(years.max) or minYear
  if not minYear then
    return nil, nil
  end
  if not maxYear then
    maxYear = minYear
  end
  if minYear > maxYear then
    minYear, maxYear = maxYear, minYear
  end
  return minYear, maxYear
end

local function isDiscreteMatch(value, wanted)
  if value == wanted then
    return true
  end
  if normalizeToken(value) ~= '' and normalizeToken(value) == normalizeToken(wanted) then
    return true
  end
  if type(value) ~= 'table' then
    return false
  end
  if value[wanted] then return true end
  if value[tostring(wanted)] then return true end
  if value[normalizeToken(wanted)] then return true end
  local wantedToken = normalizeToken(wanted)
  for key, keyed in pairs(value) do
    if keyed and normalizeToken(key) == wantedToken then
      return true
    end
  end
  for _, item in ipairs(value) do
    if item == wanted or (normalizeToken(item) ~= '' and normalizeToken(item) == wantedToken) then
      return true
    end
  end
  return false
end

local function doesVehicleMatchFilterRule(vehicleInfo, filterName, parameters)
  if filterName == 'Years' then
    local minYear, maxYear = getVehicleYearRange(vehicleInfo)
    if not minYear then
      return false
    end
    local minAllowed = tonumber(parameters and parameters.min)
    local maxAllowed = tonumber(parameters and parameters.max)
    if minAllowed and maxYear < minAllowed then
      return false
    end
    if maxAllowed and minYear > maxAllowed then
      return false
    end
    return true
  end

  if isRangeParams(parameters) then
    local value = getVehicleFieldValue(vehicleInfo, filterName)
    local numberValue = tonumber(value)
    if numberValue == nil and type(value) == 'table' then
      numberValue = tonumber(value.min) or tonumber(value.max)
    end
    if numberValue == nil then
      return false
    end

    local minAllowed = tonumber(parameters.min)
    local maxAllowed = tonumber(parameters.max)
    if minAllowed and numberValue < minAllowed then
      return false
    end
    if maxAllowed and numberValue > maxAllowed then
      return false
    end
    return true
  end

  local value = getVehicleFieldValue(vehicleInfo, filterName)
  if type(parameters) ~= 'table' then
    return isDiscreteMatch(value, parameters)
  end

  for _, wanted in ipairs(parameters) do
    if isDiscreteMatch(value, wanted) then
      return true
    end
  end
  return false
end

local function doesVehicleMatchFilterList(vehicleInfo, filters, requireAll)
  if type(filters) ~= 'table' or next(filters) == nil then
    return requireAll and true or false
  end

  for filterName, parameters in pairs(filters) do
    local matched = doesVehicleMatchFilterRule(vehicleInfo, filterName, parameters)
    if requireAll then
      if not matched then
        return false
      end
    elseif matched then
      return true
    end
  end

  return requireAll and true or false
end

local function doesVehiclePassAuctionFilter(vehicleInfo, filter)
  local normalized = normalizeFilterDefinition(filter)
  if not doesVehicleMatchFilterList(vehicleInfo, normalized.whiteList, true) then
    return false
  end
  if doesVehicleMatchFilterList(vehicleInfo, normalized.blackList, false) then
    return false
  end
  return true
end

local function buildRelaxedFallbackFilter(filter)
  local normalized = normalizeFilterDefinition(filter)
  local relaxed = {
    whiteList = {},
    blackList = deepCopy(normalized.blackList or {})
  }

  for filterName, parameters in pairs(normalized.whiteList or {}) do
    local key = normalizeToken(filterName)
    if not isRangeParams(parameters) and key ~= 'years' and key ~= 'mileage' and key ~= 'population' and key ~= 'value' then
      relaxed.whiteList[filterName] = deepCopy(parameters)
    end
  end

  return relaxed
end

local function getRandomVehicleDefWithFilter(filter)
  local eligibleVehicles = util_configListGenerator.getEligibleVehicles(false, false)
  local normalizedFilter = normalizeFilterDefinition(filter or {})
  local infos = util_configListGenerator.getRandomVehicleInfos({filter = {}}, 140, eligibleVehicles, 'Population')

  for _, info in ipairs(infos or {}) do
    if doesVehiclePassAuctionFilter(info, normalizedFilter) then
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
          mileage = getMileageFromInfo(info) or getFallbackMileage(),
          year = tonumber(info.Year) or tonumber(info.year) or
            (type(info.Years) == 'table' and tonumber(info.Years.max)) or getCurrentYear()
        }
      end
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

local function getRandomVehicleDefNoFilter(enforceFilter)
  local eligibleVehicles = util_configListGenerator.getEligibleVehicles(false, false)
  local infos = util_configListGenerator.getRandomVehicleInfos({filter = {}}, 80, eligibleVehicles, 'Population')
  local normalizedFilter = normalizeFilterDefinition(enforceFilter or {})

  for _, info in ipairs(infos or {}) do
    if doesVehiclePassAuctionFilter(info, normalizedFilter) then
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
          mileage = getMileageFromInfo(info) or getFallbackMileage(),
          year = tonumber(info.Year) or tonumber(info.year) or
            (type(info.Years) == 'table' and tonumber(info.Years.max)) or getCurrentYear()
        }
      end
    end
  end

  return nil
end

local function clampNumber(v, minV, maxV)
  if v < minV then return minV end
  if v > maxV then return maxV end
  return v
end

local function roundDownToStep(value, step)
  local s = math.max(1, tonumber(step) or 1)
  return math.floor(math.max(0, tonumber(value) or 0) / s) * s
end

local function roundToNearestStep(value, step)
  local s = math.max(1, tonumber(step) or 1)
  local normalized = math.max(0, tonumber(value) or 0) / s
  return math.floor(normalized + 0.5) * s
end

local function makeFallbackAuctionPersona(index)
  local fallbackProfiles = {
    {name = 'Bidder A', priceMultiplier = 0.92, counterOfferReadiness = 0.75, unpredictability = 0.06},
    {name = 'Bidder B', priceMultiplier = 1.00, counterOfferReadiness = 0.55, unpredictability = 0.04},
    {name = 'Bidder C', priceMultiplier = 1.08, counterOfferReadiness = 0.82, unpredictability = 0.08}
  }
  local profile = fallbackProfiles[index] or fallbackProfiles[((index - 1) % #fallbackProfiles) + 1]
  return {
    name = profile.name,
    priceMultiplier = profile.priceMultiplier,
    counterOfferReadiness = profile.counterOfferReadiness,
    unpredictability = profile.unpredictability
  }
end

local function generateAuctionNpcPersonas(count)
  local personas = {}
  local usedNames = {}
  count = math.max(1, tonumber(count) or constants.NPC_PERSONA_COUNT)

  for i = 1, count do
    local personality = nil
    if career_modules_marketplace and career_modules_marketplace.generatePersonality then
      personality = career_modules_marketplace.generatePersonality(true)
    end
    if type(personality) ~= 'table' then
      personality = makeFallbackAuctionPersona(i)
    end

    local baseName = tostring(personality.name or ('Bidder ' .. tostring(i)))
    if baseName == '' then
      baseName = 'Bidder ' .. tostring(i)
    end

    local name = baseName
    local suffix = 2
    while usedNames[name] do
      name = string.format('%s %d', baseName, suffix)
      suffix = suffix + 1
    end
    usedNames[name] = true

    table.insert(personas, {
      id = string.format('npc_%d', i),
      name = name,
      archetype = personality.archetype,
      priceMultiplier = tonumber(personality.priceMultiplier) or 1.0,
      counterOfferReadiness = tonumber(personality.counterOfferReadiness) or 0.5,
      unpredictability = tonumber(personality.unpredictability) or 0.03
    })
  end

  return personas
end

local function computeNpcMaxBidForLot(basePrice, startBid, minStep, persona)
  local priceMultiplier = tonumber((persona or {}).priceMultiplier) or 1.0
  local readiness = tonumber((persona or {}).counterOfferReadiness) or 0.5
  local unpredictability = tonumber((persona or {}).unpredictability) or 0.03
  local personaBias = clampNumber(
    (priceMultiplier - 1.0) * 0.55 +
    (readiness - 0.5) * 0.35 +
    (unpredictability - 0.03) * 2.5,
    -0.35, 0.35
  )
  local roll = clampNumber(math.random() + personaBias, 0, 1)
  local targetMult = constants.NPC_MAX_BID_MULT_MIN + roll * (constants.NPC_MAX_BID_MULT_MAX - constants.NPC_MAX_BID_MULT_MIN)
  local maxBid = roundDownToStep((tonumber(basePrice) or 0) * targetMult, minStep)
  maxBid = math.max(maxBid, (tonumber(startBid) or 0) + (tonumber(minStep) or 250) * 2)
  maxBid = math.min(maxBid, roundDownToStep((tonumber(basePrice) or 0) * constants.NPC_MAX_BID_MULT_MAX, minStep))
  return maxBid
end

local function chooseInitialNpcLeader(personas, maxBidsByPersonaId, startBid, minStep)
  local nextBid = (tonumber(startBid) or 0) + (tonumber(minStep) or 250)
  local eligible = {}
  local strongest, strongestMax = nil, -math.huge

  for _, persona in ipairs(personas or {}) do
    local maxBid = tonumber(maxBidsByPersonaId and maxBidsByPersonaId[persona.id]) or 0
    if maxBid >= nextBid then
      table.insert(eligible, persona)
    end
    if maxBid > strongestMax then
      strongest = persona
      strongestMax = maxBid
    end
  end

  if #eligible > 0 then
    return eligible[math.random(1, #eligible)]
  end
  return strongest
end

local function prepareLots(spawnSpots, blockSpots, lotCount, npcPersonas)
  local lots = {}
  local spawnCount = #(spawnSpots or {})
  if spawnCount <= 0 then
    return lots
  end

  lotCount = math.max(1, tonumber(lotCount) or constants.DEFAULT_LOT_COUNT)
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
      local relaxedFallbackFilter = buildRelaxedFallbackFilter(lotFilter)
      vehicleDef = getRandomVehicleDefWithFilter(relaxedFallbackFilter)
      if not vehicleDef then
        vehicleDef = getRandomVehicleDefNoFilter(relaxedFallbackFilter)
      end
    end
    if not vehicleDef then
      vehicleDef = fallbackPool[math.random(1, #fallbackPool)]
    end

    local minStep = 250
    local startBid = roundToNearestStep(vehicleDef.basePrice * (0.55 + math.random() * 0.2), 500)
    local lotNpcMaxBidsByPersonaId = {}
    local lotNpcNamesById = {}

    for _, persona in ipairs(npcPersonas or {}) do
      lotNpcMaxBidsByPersonaId[persona.id] = computeNpcMaxBidForLot(vehicleDef.basePrice, startBid, minStep, persona)
      lotNpcNamesById[persona.id] = persona.name
    end

    local startingLeader = chooseInitialNpcLeader(npcPersonas, lotNpcMaxBidsByPersonaId, startBid, minStep)

    table.insert(lots, {
      lotIndex = i,
      spawnSpot = spawnSpot,
      blockSpot = blockSpot,
      model = vehicleDef.model,
      config = vehicleDef.config,
      title = vehicleDef.title,
      basePrice = vehicleDef.basePrice,
      mileage = vehicleDef.mileage or getFallbackMileage(),
      year = vehicleDef.year or getCurrentYear(),
      minStep = minStep,
      currentBid = startBid,
      highestBidder = 'npc',
      highestBidderName = (startingLeader and startingLeader.name) or 'NPC',
      leadingNpcPersonaId = startingLeader and startingLeader.id or nil,
      npcMaxBidsByPersonaId = lotNpcMaxBidsByPersonaId,
      npcPersonaNamesById = lotNpcNamesById,
      extensionCount = 0,
      endTime = 0,
      state = 'pending',
      vehId = nil,
      wonByPlayer = false,
      wonInventoryId = nil,
      driveState = nil,
      driveStartedAt = 0,
      lastMotionPos = nil,
      lastMotionAt = 0,
      nextApproachControlAt = 0
    })
  end

  return lots
end

local showLiveAuctionStatus

local function maybeExtendLotTimer(lot)
  if not lot or lot.state ~= 'active' then return false end
  local now = getAuctionTime()
  local remaining = (lot.endTime or 0) - now
  if remaining > constants.ANTI_SNIPE_WINDOW then
    return false
  end

  lot.endTime = (lot.endTime or now) + constants.ANTI_SNIPE_EXTEND
  lot.extensionCount = (lot.extensionCount or 0) + 1
  return true
end

local function getLotLeaderName(lot)
  if not lot then return '-' end
  if lot.highestBidder == 'player' then
    return 'You'
  end
  if lot.highestBidder == 'npc' then
    if lot.highestBidderName and lot.highestBidderName ~= '' then
      return lot.highestBidderName
    end
    local npcName = lot.npcPersonaNamesById and lot.leadingNpcPersonaId and lot.npcPersonaNamesById[lot.leadingNpcPersonaId]
    if npcName and npcName ~= '' then
      return npcName
    end
    return 'NPC'
  end
  return '-'
end

local function setPlayerAsLeader(lot)
  if not lot then return end
  lot.highestBidder = 'player'
  lot.leadingNpcPersonaId = nil
  lot.highestBidderName = 'You'
end

local function setNpcAsLeader(lot, persona)
  if not lot then return end
  lot.highestBidder = 'npc'
  lot.leadingNpcPersonaId = persona and persona.id or nil
  local npcName = persona and persona.name or nil
  if (not npcName or npcName == '') and lot.npcPersonaNamesById and lot.leadingNpcPersonaId then
    npcName = lot.npcPersonaNamesById[lot.leadingNpcPersonaId]
  end
  lot.highestBidderName = npcName or 'NPC'
end

local function chooseNpcBidIncrement(persona, currentBid, cap)
  local bid = tonumber(currentBid) or 0
  local c = tonumber(cap) or 0
  local room = c - bid
  if room < 250 then
    return nil
  end
  local affordable = {}
  for _, inc in ipairs(constants.NPC_BID_INCREMENTS) do
    if inc <= room then
      table.insert(affordable, inc)
    end
  end
  if #affordable == 0 then
    return nil
  end
  local readiness = tonumber(persona and persona.counterOfferReadiness) or 0.5
  local priceMult = tonumber(persona and persona.priceMultiplier) or 1.0
  local unpredictability = tonumber(persona and persona.unpredictability) or 0.03
  local aggression = clampNumber(
    0.55 + (readiness - 0.5) * 0.9 + (priceMult - 1.0) * 0.5 + unpredictability * 2.8,
    0.25, 2.0
  )
  local totalW = 0
  local weights = {}
  for _, inc in ipairs(affordable) do
    local w = math.max(0.01, (inc / 250) ^ aggression)
    table.insert(weights, w)
    totalW = totalW + w
  end
  local roll = math.random() * totalW
  local acc = 0
  for i, w in ipairs(weights) do
    acc = acc + w
    if roll <= acc then
      return affordable[i]
    end
  end
  return affordable[#affordable]
end

local function chooseNpcBidderForLot(lot, preferOutbid)
  if not lot then return nil end
  local currentBid = tonumber(lot.currentBid) or 0
  local baseline = math.max(tonumber(lot.basePrice) or 0, currentBid, 1)
  local candidates = {}
  local totalWeight = 0

  for _, persona in ipairs(auctionState.npcPersonas or {}) do
    local cap = tonumber(lot.npcMaxBidsByPersonaId and lot.npcMaxBidsByPersonaId[persona.id]) or 0
    local canBid = cap >= currentBid + 250
    local sameLeader = (lot.highestBidder == 'npc' and lot.leadingNpcPersonaId == persona.id)
    if canBid and not sameLeader then
      local readiness = tonumber(persona.counterOfferReadiness) or 0.5
      local unpredictability = tonumber(persona.unpredictability) or 0.03
      local headroom = clampNumber((cap - currentBid) / baseline, 0, 1)
      local weight = 0.75 + readiness * 0.9 + unpredictability * 1.5 + headroom * 0.8
      if preferOutbid then
        weight = weight * 1.15
      end

      totalWeight = totalWeight + math.max(0.01, weight)
      table.insert(candidates, {persona = persona, weight = math.max(0.01, weight)})
    end
  end

  if #candidates == 0 then
    return nil
  end

  local roll = math.random() * totalWeight
  local acc = 0
  for _, item in ipairs(candidates) do
    acc = acc + item.weight
    if roll <= acc then
      return item.persona
    end
  end

  return candidates[#candidates].persona
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

local function getAuctionVehiclePartsValue(modelName, configKey)
  if not modelName or not configKey then
    return 0
  end

  local cacheKey = tostring(modelName) .. '|' .. tostring(configKey)
  if partsValueCache[cacheKey] ~= nil then
    return partsValueCache[cacheKey]
  end

  local ioCtx = {
    preloadedDirs = {'/vehicles/' .. modelName .. '/'}
  }

  local pcPath = 'vehicles/' .. modelName .. '/' .. configKey .. '.pc'
  local readOk, pcData = pcall(jsonReadFile, pcPath)
  if not readOk or not pcData or type(pcData.parts) ~= 'table' then
    local logKey = cacheKey .. '|partsMissing'
    if not badConfigLogOnce[logKey] then
      badConfigLogOnce[logKey] = true
      log('W', 'UsedAuction', string.format('Unable to read parts from %s, keeping base price fallback.', pcPath))
    end
    return 0
  end

  local valueOk, totalValue = pcall(function()
    local accumulatedValue = 0
    for _, partName in pairs(pcData.parts) do
      if partName and partName ~= '' then
        local partData = jbeamIO.getPart(ioCtx, partName)
        if partData and partData.information and partData.information.value then
          accumulatedValue = accumulatedValue + partData.information.value
        end
      end
    end
    return accumulatedValue
  end)

  if not valueOk then
    local logKey = cacheKey .. '|partsValueError'
    if not badConfigLogOnce[logKey] then
      badConfigLogOnce[logKey] = true
      log('W', 'UsedAuction', string.format(
        'Part value lookup failed for %s, keeping base price fallback (%s).',
        cacheKey, tostring(totalValue)))
    end
    return 0
  end

  partsValueCache[cacheKey] = totalValue
  return totalValue
end

local function computeConditionedLotBasePrice(lot)
  if not lot or not career_modules_valueCalculator then
    return nil
  end

  local baseValue = tonumber(lot.basePrice) or tonumber(lot.currentBid) or 0
  if baseValue <= 0 then
    return nil
  end

  local mileageMeters = getLotMileageMeters(lot)
  local vehicleYear = tonumber(lot.year) or getCurrentYear()
  local currentYear = getCurrentYear()
  local vehicleAge = math.max(0, currentYear - vehicleYear)

  local adjustedBaseValue = career_modules_valueCalculator.getAdjustedVehicleBaseValue(baseValue, {
    mileage = mileageMeters,
    age = vehicleAge
  })

  local configKey = getConfigKeyFromPath(lot.config)
  local partsBaseValue = getAuctionVehiclePartsValue(lot.model, configKey)
  local conditionedPartsValue = 0
  if partsBaseValue > 0 then
    conditionedPartsValue = math.floor(
      career_modules_valueCalculator.getDepreciatedPartValue(partsBaseValue, mileageMeters) * 1.081
    )
  end

  local conditioned = math.max(adjustedBaseValue or 0, conditionedPartsValue or 0)
  if conditioned <= 0 then
    return nil
  end

  conditioned = math.floor(conditioned / 1000) * 1000
  return math.max(1500, conditioned)
end

local function applyConditionedLotPricing(lot)
  if not lot or lot.pricingInitialized then
    return
  end

  local conditionedBase = computeConditionedLotBasePrice(lot)
  if not conditionedBase then
    lot.pricingInitialized = true
    return
  end

  lot.basePrice = conditionedBase
  lot.conditionedBasePrice = conditionedBase

  local minStep = lot.minStep or 250
  local startBid = roundToNearestStep(conditionedBase * (0.55 + math.random() * 0.2), 500)
  startBid = math.max(minStep, startBid)
  lot.currentBid = startBid

  lot.npcMaxBidsByPersonaId = {}
  lot.npcPersonaNamesById = lot.npcPersonaNamesById or {}
  for _, persona in ipairs(auctionState.npcPersonas or {}) do
    lot.npcMaxBidsByPersonaId[persona.id] = computeNpcMaxBidForLot(conditionedBase, startBid, minStep, persona)
    lot.npcPersonaNamesById[persona.id] = persona.name
  end

  local leader = chooseInitialNpcLeader(auctionState.npcPersonas, lot.npcMaxBidsByPersonaId, startBid, minStep)
  if leader then
    setNpcAsLeader(lot, leader)
  else
    lot.highestBidder = 'npc'
    lot.leadingNpcPersonaId = nil
    lot.highestBidderName = 'NPC'
  end

  lot.pricingInitialized = true
end

local function applyRandomPaintToSpawnOptions(options, modelKey, configPath)
  if not options or not modelKey then return end
  if not core_vehiclePaints or not core_vehiclePaints.getRandomPaints then return end

  local paintResult = core_vehiclePaints.getRandomPaints(modelKey, getConfigKeyFromPath(configPath))
  if type(paintResult) ~= 'table' then return end

  local modelData = core_vehicles.getModel(modelKey)
  local modelPaints = modelData and modelData.model and modelData.model.paints
  if type(modelPaints) ~= 'table' then return end

  local paintName = paintResult.paintName1
  local paint1 = paintName and modelPaints[paintName]
  if not paint1 then
    return
  end

  -- Only randomize paint slot 1 for auction vehicles.
  options.paintName = paintName
  options.paint = deepCopy(paint1)

  -- Also embed paints into config data before spawn so loaded config keeps auction paint.
  if type(configPath) == 'string' then
    local cfg = jsonReadFile(configPath)
    if type(cfg) == 'table' and cfg.format ~= 4 then
      cfg = deepCopy(cfg)
      cfg.partConfigFilename = configPath
      cfg.colors = nil
      local paints = type(cfg.paints) == 'table' and deepCopy(cfg.paints) or {}
      paints[1] = deepCopy(options.paint)
      cfg.paints = paints
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

  core_vehicleBridge.executeAction(veh, 'initPartConditions', {}, getLotMileageMeters(lot), 1, 1)
  applyConditionedLotPricing(lot)

  lot.vehId = veh:getID()
  lot.state = startApproach and 'approaching' or 'queued'
  lot.driveState = startApproach and 'approach' or nil
  lot.driveStartedAt = getAuctionTime()
  lot.lastMotionPos = vec3(veh:getPosition())
  lot.lastMotionAt = lot.driveStartedAt
  gameplay_traffic.insertTraffic(lot.vehId, true)
  veh:queueLuaCommand('electrics.setLightsState(1)')
  setLotVehicleDriveLock(veh, startApproach and 'transit' or 'staged')
  if startApproach then
    veh:queueLuaCommand('ai.setSpeedMode("set")')
    veh:queueLuaCommand(string.format('ai.setSpeed(%.4f)', constants.AI_MAX_SPEED_MPS))
  end

  return true
end

local function beginLotBidding(lot, forceTeleportToBlock)
  if not lot then return end
  openMenu()

  local veh = lot.vehId and getObjectByID(lot.vehId)
  if veh then
    if forceTeleportToBlock then
      teleportVehicleToSpot(veh, lot.blockSpot or lot.spawnSpot)
    end
    setLotVehicleDriveLock(veh, 'bidding')
  end

  lot.state = 'active'
  lot.driveState = nil
  local now = getAuctionTime()
  lot.endTime = now + constants.LOT_DURATION
  auctionState.nextNpcBidAt = now + 1.0
  auctionState.nextPlayerBidCheckAt = now + 0.5
  auctionState.nextLiveStatusAt = 0
  showLiveAuctionStatus(true)
end

local function setLotMotionTrackingNow(lot, veh)
  if not lot or not veh then
    return
  end
  lot.driveStartedAt = getAuctionTime()
  lot.lastMotionPos = vec3(veh:getPosition())
  lot.lastMotionAt = lot.driveStartedAt
end

local function beginLotApproach(lot)
  if not lot then return false end
  local veh = lot.vehId and getObjectByID(lot.vehId)
  if not veh then return false end
  setLotVehicleDriveLock(veh, 'transit')
  lot.state = 'approaching'
  lot.driveState = 'approach'
  setLotMotionTrackingNow(lot, veh)
  lot.nextApproachControlAt = 0

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

  closeVehicleOpenables(veh)
  setLotVehicleDriveLock(veh, 'transit')
  lot.state = 'exiting'
  lot.driveState = 'exit'
  setLotMotionTrackingNow(lot, veh)

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
  setAuctionRunningTriggerState()
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

  local now = getAuctionTime()
  if not force and now < (auctionState.nextLiveStatusAt or 0) then
    return
  end

  auctionState.nextLiveStatusAt = now + constants.LIVE_STATUS_INTERVAL
end

local function applyPlayerBidToLot(lot, bidAmount)
  if not lot then
    return false
  end

  auctionState.bidHint = nil
  auctionState.bidHintUntil = 0

  lot.currentBid = bidAmount
  setPlayerAsLeader(lot)
  playBidAcceptedSound()
  maybeExtendLotTimer(lot)
  scheduleNextNpcBid()
  showLiveAuctionStatus(true)
  return true
end

local function refreshLotMotionProgress(lot, veh, tNow)
  if not lot or not veh then return end
  local currentPos = vec3(veh:getPosition())
  local prevPos = lot.lastMotionPos
  if not prevPos then
    lot.lastMotionPos = currentPos
    lot.lastMotionAt = tNow
    return
  end

  if (currentPos - prevPos):length() >= constants.LOT_PROGRESS_DISTANCE then
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

local function getActiveAuctionLot()
  for _, lot in ipairs(auctionState.lots or {}) do
    if lot.state == 'active' then
      return lot
    end
  end
  return nil
end

local function setBidHint(text, seconds)
  auctionState.bidHint = text
  auctionState.bidHintUntil = getAuctionTime() + (tonumber(seconds) or 4)
end

local function placePlayerBidIfPossible()
  if auctionState.phase ~= 'bidding' then
    setBidHint('Auction is not taking bids right now.', 3)
    return false
  end

  local lot = getActiveAuctionLot()
  if not lot or lot.state ~= 'active' then
    setBidHint('Wait until this lot is live on the block.', 3)
    return false
  end
  if lot.highestBidder == 'player' then
    setBidHint('You already have the high bid.', 3)
    return false
  end

  local bidAmount = lot.currentBid + lot.minStep

  if not canAfford(bidAmount) then
    setBidHint('Not enough money for this bid.', 5)
    return false
  end

  return applyPlayerBidToLot(lot, bidAmount)
end

local function placePlayerBidByAmount(amount)
  if auctionState.phase ~= 'bidding' then
    setBidHint('Auction is not taking bids right now.', 3)
    return false
  end
  local lot = getActiveAuctionLot()
  if not lot or lot.state ~= 'active' then
    setBidHint('Wait until this lot is live on the block.', 3)
    return false
  end
  if lot.highestBidder == 'player' then
    setBidHint('You already have the high bid.', 3)
    return false
  end

  amount = math.max(lot.minStep or 250, tonumber(amount) or 0)
  local bidAmount = lot.currentBid + amount

  if not canAfford(bidAmount) then
    setBidHint('Not enough money for this bid.', 5)
    return false
  end

  return applyPlayerBidToLot(lot, bidAmount)
end

local function requestAuctionState()
  local now = getAuctionTime()
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
      highestBidderName = getLotLeaderName(lot),
      highestBidderNpcId = lot.leadingNpcPersonaId,
      timeLeft = math.max(0, math.ceil((lot.endTime or 0) - now))
    }
    table.insert(lotsOut, lotOut)

    if not derivedCurrentLot and (lot.state == 'queued' or lot.state == 'approaching' or lot.state == 'active' or lot.state == 'exiting') then
      derivedCurrentLot = lotOut
      derivedCurrentLotIndex = lotOut.lotIndex
    end
  end

  local activeIdx = tonumber(auctionState.activeLotIndex)
  local indexedLot = (activeIdx and activeIdx >= 1) and lotsOut[activeIdx] or nil
  if indexedLot and (indexedLot.state == 'queued' or indexedLot.state == 'approaching' or indexedLot.state == 'active' or indexedLot.state == 'exiting') then
    derivedCurrentLot = indexedLot
    derivedCurrentLotIndex = indexedLot.lotIndex
  end

  local hasLiveLot = derivedCurrentLot ~= nil
  local derivedPhase = auctionState.phase
  if hasLiveLot and (derivedPhase == 'idle' or derivedPhase == 'starting') then
    derivedPhase = 'bidding'
  end
  if auctionState.entryPromptActive and derivedPhase == 'idle' then
    derivedPhase = 'entryPrompt'
  end

  local bidMessage = ''
  if (auctionState.bidHintUntil or 0) > now and auctionState.bidHint and auctionState.bidHint ~= '' then
    bidMessage = tostring(auctionState.bidHint)
  end

  local status = 'Enter the auction trigger to begin.'
  if derivedPhase == 'entryPrompt' then
    local fee = getAuctionEntryFee()
    if not hasGarageSpaceForPurchase() then
      status = 'You need at least one free garage slot to enter the auction.'
    elseif canAffordAuctionEntry() then
      status = string.format('Pay $%d to enter the auction.', fee)
    else
      status = string.format('Not enough money. $%d required to enter.', fee)
    end
  elseif derivedPhase == 'bidding' then
    status = 'Auction in progress.'
  elseif derivedPhase == 'complete' then
    status = 'Auction complete. Use exit trigger to return.'
  end

  return {
    phase = derivedPhase,
    entryPromptActive = auctionState.entryPromptActive and true or false,
    musicEnabled = auctionState.musicEnabled ~= false,
    entryFee = getAuctionEntryFee(),
    canPayEntryFee = canAffordAuctionEntry(),
    hasFreeGarageSlot = hasGarageSpaceForPurchase(),
    activeLotIndex = auctionState.activeLotIndex,
    currentLotIndex = derivedCurrentLotIndex,
    hasLiveLot = hasLiveLot,
    currentLot = derivedCurrentLot,
    statusMessage = status,
    purchasedCount = #(auctionState.purchasedInventoryIds or {}),
    autoBidEnabled = false,
    autoBidMax = 0,
    bidMessage = bidMessage,
    lots = lotsOut
  }
end

local function placeBid(amount)
  if amount and tonumber(amount) and tonumber(amount) > 0 then
    return placePlayerBidByAmount(tonumber(amount))
  end
  return placePlayerBidIfPossible()
end

local function setAutoBidEnabled(enabled)
  -- Legacy API kept as no-op for compatibility with stale UI callers.
  return false
end

local function setAutoBidMax(maxBid)
  -- Legacy API kept as no-op for compatibility with stale UI callers.
  return false
end

local function setAuctionMusicEnabled(enabled)
  auctionState.musicEnabled = enabled and true or false
  if auctionState.phase ~= 'idle' then
    setAuctionActiveAssetsEnabled(true)
  end
  saveAuctionSettings()
  return auctionState.musicEnabled
end

local function passCurrentLot()
  -- Passing lots is intentionally disabled.
  return false
end

local function closeMenuUiOnly()
  closeAuctionOverlayUi()
end

local function canStartAuctionFromPrompt()
  if auctionState.transitionActive then
    return false, 'Auction is busy right now.'
  end

  local playerVeh = getPlayerVehicle()
  if not playerVeh then
    return false, 'No player vehicle available.'
  end

  local spots = getSiteParkingSpots()
  if not spots or #spots < 1 then
    return false, 'Auction spots missing in auction.sites.json'
  end

  local layout = buildSiteLayout(spots)
  if not layout.playerSpot then
    return false, 'Missing spot tag: auctionPlayerStart.'
  end
  if #layout.spawnSpots < 1 then
    return false, 'Missing spot tag: auctionSpawn.'
  end
  if not layout.despawnSpot then
    return false, 'Missing spot tag: auctionDespawn.'
  end
  if not getPlayerExitSpot(layout, false) then
    return false, 'Missing spot tag: auctionPlayerExit (and no trigger fallback).'
  end
  if not hasGarageSpaceForPurchase() then
    return false, 'No free garage slot.'
  end

  return true
end

local function openEntryPrompt()
  if auctionState.phase ~= 'idle' or auctionState.transitionActive then
    return false
  end
  auctionState.entryPromptActive = true
  openMenu()
  return true
end

local function cancelEntryPrompt(closeUi)
  if auctionState.phase ~= 'idle' then
    if closeUi then
      closeMenuUiOnly()
    end
    return false
  end

  if not auctionState.entryPromptActive then
    if closeUi then
      closeMenuUiOnly()
    end
    return false
  end

  auctionState.entryPromptActive = false

  if closeUi then
    closeMenuUiOnly()
  end
  return true
end

local function confirmEntryPaymentAndStartAuction()
  if auctionState.phase ~= 'idle' or not auctionState.entryPromptActive then
    return false
  end

  local canStart = canStartAuctionFromPrompt()
  if not canStart then
    return false
  end

  if not hasGarageSpaceForPurchase() then
    return false
  end

  if not canAffordAuctionEntry() then
    return false
  end

  if core_gamestate and core_gamestate.requestEnterLoadingScreen then
    playUiSound(constants.AUCTION_ENTRY_PAYMENT_SFX_EVENT)
    core_gamestate.requestEnterLoadingScreen(constants.AUCTION_ENTRY_LOADING_TAG, function()
      if not payAuctionEntryFee() then
        exitAuctionEntryLoadingScreen()
        return
      end

      if career_saveSystem and career_saveSystem.saveCurrent then
        pcall(function() career_saveSystem.saveCurrent() end)
      end

      auctionState.entryPromptActive = false
      if not startAuctionImmediate() then
        exitAuctionEntryLoadingScreen()
      end
    end)
    return true
  end

  if not payAuctionEntryFee() then
    return false
  end

  playUiSound(constants.AUCTION_ENTRY_PAYMENT_SFX_EVENT)
  if career_saveSystem and career_saveSystem.saveCurrent then
    pcall(function() career_saveSystem.saveCurrent() end)
  end

  auctionState.entryPromptActive = false
  return startAuctionImmediate()
end

local function closeMenu()
  if auctionState.phase == 'idle' and auctionState.entryPromptActive then
    return cancelEntryPrompt(true)
  end
  closeMenuUiOnly()
  return true
end

local function startAuction()
  if auctionState.phase ~= 'idle' then
    return false
  end
  if auctionState.entryPromptActive then
    return confirmEntryPaymentAndStartAuction()
  end
  return openEntryPrompt()
end

local function cancelTravelPrompt()
  if auctionState.phase == 'idle' and auctionState.entryPromptActive then
    return cancelEntryPrompt(true)
  end
  return closeMenu()
end

local function finishCurrentLot()
  local lot = getActiveAuctionLot()
  if not lot or lot.state ~= 'active' then
    return
  end

  lot.state = 'finished'

  if lot.highestBidder == 'player' then
    if not hasGarageSpaceForPurchase() then
    elseif canAfford(lot.currentBid) then
      payForVehicle(lot.currentBid, string.format('Used Auction: %s', lot.title))
      local inventoryId = career_modules_inventory.addVehicle(lot.vehId, nil, {owned = true})
      if inventoryId then
        if not career_modules_inventory.moveVehicleToGarage(inventoryId) then
          career_modules_inventory.removeVehicle(inventoryId)
          beginLotExit(lot)
          startNextLotAfter(lot.lotIndex)
          return
        end
        lot.wonByPlayer = true
        lot.wonInventoryId = inventoryId
        table.insert(auctionState.purchasedInventoryIds, inventoryId)
        playLotWinCelebrationSound()
        triggerAuctionWinEmitters(constants.LOT_WIN_EMITTER_DURATION)
      end
    end
  end

  beginLotExit(lot)
  startNextLotAfter(lot.lotIndex)
end

local function resetAuction(keepPurchases)
  closeAuctionOverlayUi()
  clearAuctionExitMarker()

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
  auctionState.switchWarnCooldownUntil = 0
  auctionState.lastValidPlayerVehId = nil
  auctionState.entryPromptActive = false
  auctionState.awaitingFinalExit = false
  auctionState.npcPersonas = {}
  auctionState.winEmitterPulseToken = (auctionState.winEmitterPulseToken or 0) + 1
  setAuctionWinEmittersEnabled(false)
  setAuctionActiveAssetsEnabled(false)

  auctionState.purchasedInventoryIds = {}
  auctionState.bidHint = nil
  auctionState.bidHintUntil = 0

  setIdleTriggerState()
end

startAuctionImmediate = function()
  if auctionState.phase ~= 'idle' or auctionState.transitionActive then
    return false
  end

  setAuctionWinEmittersEnabled(false)
  setAuctionActiveAssetsEnabled(false)

  local playerVeh = getPlayerVehicle()
  if not playerVeh then
    return false
  end
  auctionState.lastValidPlayerVehId = playerVeh:getID()

  local spots = getSiteParkingSpots()
  if not spots or #spots < 1 then
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
      resetAuction(false)
      return
    end
    if #layout.spawnSpots < 1 then
      resetAuction(false)
      return
    end
    if not layout.despawnSpot then
      resetAuction(false)
      return
    end
    if not getPlayerExitSpot(layout, true) then
      resetAuction(false)
      return
    end

    teleportVehicleToSpot(playerVeh, auctionState.auctionSpot)
    setAuctionActiveAssetsEnabled(true)
    ensureAuctionExitMarker(layout)

    auctionState.npcPersonas = generateAuctionNpcPersonas(constants.NPC_PERSONA_COUNT)
    auctionState.lots = prepareLots(layout.spawnSpots, layout.blockSpots, constants.DEFAULT_LOT_COUNT, auctionState.npcPersonas)
    auctionState.activeLotIndex = 0
    auctionState.awaitingFinalExit = false

    local started = startNextLotAfter(0)
    if not started then
      setAuctionComplete()
      return
    end

    auctionState.phase = 'bidding'
    openMenu()
  end)

  return true
end

local function distributePurchasedVehiclesAround(pos, baseRot)
  local returnSpots = ((auctionState.siteLayout or {}).returnSpots) or {}
  local availableReturnSpots = {}
  for _, spot in ipairs(returnSpots) do
    table.insert(availableReturnSpots, spot)
  end

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
      local movedToReturnSpot = false
      local returnSpot = getBestReturnSpotForVehicle(veh:getID(), availableReturnSpots)
      if returnSpot and returnSpot.moveResetVehicleTo then
        local ok = pcall(function()
          returnSpot:moveResetVehicleTo(veh:getID(), nil, nil, nil, nil, true)
        end)
        if ok then
          movedToReturnSpot = true
          removeSpotFromList(availableReturnSpots, returnSpot)
        end
      end

      if not movedToReturnSpot then
        local row = math.floor((placed - 1) / 2)
        local side = ((placed - 1) % 2 == 0) and 1 or -1
        local offset = vec3((6 + row * 4) * side, -8 - (row * 4), 0)
        local worldOffset = baseRot * offset
        local target = pos + worldOffset
        local rot = quat(0, 0, 1, 0) * baseRot
        veh:setPosRot(target.x, target.y, target.z + 0.5, rot.x, rot.y, rot.z, rot.w)
      end
      stopVehicleAI(veh)
      setLotVehicleDriveLock(veh, 'released')
    end
  end
end

local function exitAuctionArea()
  if auctionState.transitionActive then
    return false
  end

  closeAuctionOverlayUi()

  local playerVeh = getPlayerVehicle()
  local exitSpot = getPlayerExitSpot(auctionState.siteLayout, true)
  if not playerVeh or not exitSpot then
    return false
  end

  local anchorPos = vec3(exitSpot.pos)
  local anchorRot = quat(exitSpot.rot)

  runFadedTransition(function()
    teleportVehicleToSpot(playerVeh, exitSpot)
    distributePurchasedVehiclesAround(anchorPos, anchorRot)

    if career_saveSystem then
      career_saveSystem.saveCurrent()
    end

    resetAuction(true)
    auctionState.entryCooldownUntil = getAuctionTime() + constants.ENTRY_RETRIGGER_COOLDOWN
  end)

  return true
end

local function ejectPlayerFromAuctionInteriorOnCareerLoad()
  local playerVeh = getPlayerVehicle()
  if not playerVeh then
    return false
  end

  local spots = getSiteParkingSpots()
  if not spots or #spots < 1 then
    return false
  end

  local layout = buildSiteLayout(spots)
  if not layout.playerSpot then
    return false
  end

  local exitSpot = getPlayerExitSpot(layout, true)
  if not exitSpot then
    return false
  end

  local distToAuctionCenter = (playerVeh:getPosition() - vec3(layout.playerSpot.pos)):length()
  if distToAuctionCenter > constants.LOAD_EJECT_DISTANCE then
    return false
  end

  runFadedTransition(function()
    teleportVehicleToSpot(playerVeh, exitSpot)
    auctionState.entryCooldownUntil = getAuctionTime() + constants.ENTRY_RETRIGGER_COOLDOWN
    setIdleTriggerState()
  end)

  return true
end

local function getFallbackPlayerVehicleId(oldId)
  if oldId and not isAuctionLotVehicleId(oldId) and getObjectByID(oldId) then
    return oldId
  end

  local lastValid = auctionState.lastValidPlayerVehId
  if lastValid and not isAuctionLotVehicleId(lastValid) and getObjectByID(lastValid) then
    return lastValid
  end

  return nil
end

local function warnBlockedAuctionVehicleSwitch()
  local now = getAuctionTime()
  if now < (auctionState.switchWarnCooldownUntil or 0) then
    return
  end
  auctionState.switchWarnCooldownUntil = now + constants.VEHICLE_SWITCH_REJECT_WARN_COOLDOWN
end

local function onVehicleSwitched(oldId, newId)
  if not career_career.isActive() then return end
  if be:getPlayerVehicleID(0) ~= newId then
    return
  end

  if auctionState.phase == 'idle' then
    auctionState.lastValidPlayerVehId = newId
    return
  end

  if not isAuctionLotVehicleId(newId) then
    auctionState.lastValidPlayerVehId = newId
    return
  end

  warnBlockedAuctionVehicleSwitch()

  local fallbackVehId = getFallbackPlayerVehicleId(oldId)
  if not fallbackVehId or fallbackVehId == newId then
    return
  end

  if core_jobsystem and core_jobsystem.create then
    core_jobsystem.create(function(job)
      job.sleep(constants.VEHICLE_SWITCH_REVERT_DELAY)
      local fallbackVeh = getObjectByID(fallbackVehId)
      if fallbackVeh then
        pcall(function() be:enterVehicle(0, fallbackVeh) end)
      end
    end)
  else
    local fallbackVeh = getObjectByID(fallbackVehId)
    if fallbackVeh then
      pcall(function() be:enterVehicle(0, fallbackVeh) end)
    end
  end
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

  if data.triggerName and data.triggerName:find(constants.ENTRY_TRIGGER) then
    if not (gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()) then
      return
    end

    if getAuctionTime() < (auctionState.entryCooldownUntil or 0) then
      return
    end

    if auctionState.phase == 'idle' then
      openEntryPrompt()
    end
    return
  end

  if data.triggerName and data.triggerName:find(constants.EXIT_TRIGGER) then
    if auctionState.phase ~= 'idle' then
      exitAuctionArea()
    end
  end
end

local function onUpdate(_, dtSim)
  local now = advanceAuctionTime(dtSim)
  if auctionState.phase ~= 'bidding' then
    return
  end

  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId and not isAuctionLotVehicleId(playerVehId) then
    auctionState.lastValidPlayerVehId = playerVehId
  end

  for _, lot in ipairs(auctionState.lots or {}) do
    if lot.state == 'approaching' then
      local lotVeh = lot.vehId and getObjectByID(lot.vehId)
      refreshLotMotionProgress(lot, lotVeh, now)
      local arrived = false
      if lotVeh then
        local blockSpot = lot.blockSpot or lot.spawnSpot
        if blockSpot then
          local distToBlock = (lotVeh:getPosition() - vec3(blockSpot.pos)):length()
          local speed = lotVeh:getVelocity():length()
          applyApproachStopControl(lot, lotVeh, distToBlock, speed, now)
          arrived = distToBlock <= constants.LOT_ARRIVE_DISTANCE and speed <= constants.LOT_ARRIVE_SPEED_MPS
        end
      end
      if arrived then
        beginLotBidding(lot, false)
      elseif (now - (lot.lastMotionAt or now) >= constants.LOT_STUCK_TIMEOUT) then
        beginLotBidding(lot, true)
      end
    elseif lot.state == 'exiting' then
      local lotVeh = lot.vehId and getObjectByID(lot.vehId)
      refreshLotMotionProgress(lot, lotVeh, now)
      local done = false
      if not lotVeh then
        done = true
      elseif auctionState.siteLayout and auctionState.siteLayout.despawnSpot then
        local dist = (lotVeh:getPosition() - vec3(auctionState.siteLayout.despawnSpot.pos)):length()
        done = dist <= constants.LOT_EXIT_DESPAWN_DISTANCE
      end

      if done or (now - (lot.lastMotionAt or now) >= constants.LOT_STUCK_TIMEOUT) then
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

  local lot = getActiveAuctionLot()
  if not lot then
    return
  end

  if now >= lot.endTime then
    finishCurrentLot()
    return
  end

  showLiveAuctionStatus(false)

  if now >= auctionState.nextPlayerBidCheckAt then
    auctionState.nextPlayerBidCheckAt = now + constants.PLAYER_BID_CHECK_INTERVAL
  end

  if now >= auctionState.nextNpcBidAt then
    local playerLeads = lot.highestBidder == 'player'
    local bidderPersona = chooseNpcBidderForLot(lot, playerLeads)
    if bidderPersona then
      local cap = tonumber(lot.npcMaxBidsByPersonaId and lot.npcMaxBidsByPersonaId[bidderPersona.id]) or 0
      local inc = chooseNpcBidIncrement(bidderPersona, lot.currentBid, cap)
      if inc then
        local baseChance = playerLeads and 0.65 or 0.35
        local readiness = tonumber(bidderPersona.counterOfferReadiness) or 0.5
        local unpredictability = tonumber(bidderPersona.unpredictability) or 0.03
        local personaChance = baseChance * clampNumber(0.75 + readiness * 0.5 + unpredictability * 2.0, 0.6, 1.35)
        if math.random() < clampNumber(personaChance, 0.05, 0.95) then
          lot.currentBid = lot.currentBid + inc
          setNpcAsLeader(lot, bidderPersona)
          playBidAcceptedSound()
          maybeExtendLotTimer(lot)
        end
      end
    end

    scheduleNextNpcBid(now)
  end
end

local function hideAuctionUiAndDisableAssets()
  hardDisableAuctionAudioVisuals()
  auctionState.uiOpen = false
  pcall(function() guihooks.trigger('UsedAuctionHide') end)
end

local function onCareerActivated()
  loadAuctionSettings()
  setIdleTriggerState()
  hideAuctionUiAndDisableAssets()
  ejectPlayerFromAuctionInteriorOnCareerLoad()
end

local function onSaveCurrentSaveSlot(currentSavePath)
  saveAuctionSettings(currentSavePath)
end

local function onCareerDeactivatedWhileLevelLoaded()
  pcall(function() guihooks.trigger('UsedAuctionHide') end)
  resetAuction(false)
end

local function onExtensionLoaded()
  hideAuctionUiAndDisableAssets()
end

local function onClientStartMission()
  hideAuctionUiAndDisableAssets()
end

local function onWorldReadyState()
  hideAuctionUiAndDisableAssets()
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if type(elements) ~= 'table' then
    return
  end

  local poi = formatAuctionEntrancePoi(levelIdentifier or getCurrentLevelIdentifier())
  if poi then
    table.insert(elements, poi)
  end
end

M.onBeamNGTrigger = onBeamNGTrigger
M.onVehicleSwitched = onVehicleSwitched
M.onUpdate = onUpdate
M.onCareerActivated = onCareerActivated
M.onCareerDeactivatedWhileLevelLoaded = onCareerDeactivatedWhileLevelLoaded
M.onExtensionLoaded = onExtensionLoaded
M.onClientStartMission = onClientStartMission
M.onWorldReadyState = onWorldReadyState
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.exitAuctionArea = exitAuctionArea
M.requestAuctionState = requestAuctionState
M.startAuction = startAuction
M.cancelTravelPrompt = cancelTravelPrompt
M.placeBid = placeBid
M.passCurrentLot = passCurrentLot
M.setAutoBidEnabled = setAutoBidEnabled
M.setAutoBidMax = setAutoBidMax
M.setAuctionMusicEnabled = setAuctionMusicEnabled
M.closeMenu = closeMenu

return M
