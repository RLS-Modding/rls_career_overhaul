local M = {}

M.dependencies = {
  'gameplay_sites_sitesManager',
  'gameplay_traffic',
  'career_modules_inventory',
  'career_modules_payment'
}

local constants = {
  ENTRY_TRIGGER = 'usedCarAuctionEntry',
  EXIT_TRIGGER = 'usedCarAuctionExit',
  COUNTER_TRIGGER_PREFIX = 'auctionCounter_',
  AUCTION_SITES_NAME = 'auction',

  LOT_DURATION = 30,
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
  MIN_LOT_COUNT = 5,
  DEFAULT_LOT_COUNT = 10,
  MAX_LOT_COUNT = 25,
  LOT_WIN_EMITTER_DURATION = 2.0,
  AUCTION_WIN_EMITTERS_GROUP = 'auctionEmitters',
  AUCTION_ACTIVE_ASSETS_GROUP = 'auctionAssetsOn',
  AUCTION_MUSIC_EMITTER_NAME = 'SFXEmitter_2',
  AUCTION_ENTRY_PAYMENT_SFX_EVENT = 'event:>UI>Career>Buy_01',
  AUCTION_ENTRY_FEE = 1000,
  AUCTION_SETTINGS_SAVE_FILE = 'usedCarAuctionSettings.json',
  AUCTION_LOT_REGISTRATION_PAYMENT_LABEL = 'Used Auction Lot Registration',
  BID_ACCEPTED_SFX_EVENT = 'event:>UI>Career>Buy_02',
  LOT_WIN_CELEBRATION_SFX_EVENT = 'event:>UI>Missions>End_Gold',
  AUCTION_POI_ID = 'usedCarAuctionEntrance',
  AUCTION_POI_LEVEL = 'west_coast_usa',
  AUCTION_POI_ICON = 'poi_fasttravel_round_orange_green',
  AUCTION_EXIT_MARKER_NAME = 'usedCarAuctionExitMarker',
  AUCTION_COUNTER_MARKER_NAME = 'usedCarAuctionCounterMarker',
  AUCTION_COUNTER_MARKER_TRIGGER = 'auctionCounter_1',
  AUCTION_COUNTER_MARKER_LABEL = 'Walk to counter',
  AUCTION_EXIT_MARKER_SHAPE = 'art/shapes/interface/checkpoint_marker.dae',
  AUCTION_EXIT_MARKER_SCALE = 2.2,
  AUCTION_EXIT_MARKER_COLOR = '1.00 0.10 0.10 0.95',
  AUCTION_COUNTER_MARKER_SCALE = 1.8,
  AUCTION_COUNTER_MARKER_COLOR = '1.00 0.55 0.10 0.95',
  AUCTION_EXIT_MARKER_Z_OFFSET = -0.8,
  AUCTION_ENTRY_LOADING_TAG = 'usedCarAuctionEntry'
}

local auctionCounterTypeTiers = {
  {
    tier = 1,
    fullFee = 1000,
    offers = {
      { id = 'anything_goes', label = 'Anything Goes', subtitle = 'No filter' },
      { id = 'budget', label = 'Budget', subtitle = 'Cheap, high-mileage cars' }
    }
  },
  {
    tier = 2,
    fullFee = 2000,
    offers = {
      { id = 'vintage', label = 'Vintage', subtitle = 'Pre-1980 vehicles' },
      { id = 'truck_night', label = 'Truck Night', subtitle = 'SUVs, vans, and pickups' }
    }
  },
  {
    tier = 3,
    fullFee = 5000,
    offers = {
      { id = 'rare_finds', label = 'Rare Finds', subtitle = 'Low-population vehicles' },
      { id = 'high_rollers', label = 'High Rollers', subtitle = 'High-end exotics' }
    }
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
  nextPlayerBidCheckAt = 0,
  nextLiveStatusAt = 0,
  transitionActive = false,
  entryCooldownUntil = 0,
  switchWarnCooldownUntil = 0,
  lastValidPlayerVehId = nil,
  entryPromptActive = false,
  counterPromptActive = false,
  uiOpen = false,
  awaitingFinalExit = false,
  npcPersonas = {},
  winEmitterPulseToken = 0,
  musicEnabled = true,
  bidHint = nil,
  bidHintUntil = 0,
  lotsRegisteredThisVisit = 0,
  counterOffers = {},
  rerollCounterOffersOnOpen = false,
  counterLotBatchSize = constants.DEFAULT_LOT_COUNT,
  entryCreditRemaining = 0
}

local pendingSavedPreAuction = nil
local stopVehicleAI
local setLotVehicleDriveLock
local startAuctionImmediate
local getPlayerExitSpot
local startLotByIndex
local hasLiveTransitionLots

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

local function buildAuctionSettingsPayload()
  local payload = {
    musicEnabled = auctionState.musicEnabled ~= false
  }
  if auctionState.phase ~= 'idle' and auctionState.returnTransform then
    local rt = auctionState.returnTransform
    local p, r = rt.pos, rt.rot
    if p and r then
      local rComb = quat(0, 0, 1, 0) * quat(r)
      payload.preAuctionVehicle = {
        px = p.x, py = p.y, pz = p.z,
        qx = rComb.x, qy = rComb.y, qz = rComb.z, qw = rComb.w
      }
    end
  end
  return payload
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

  career_saveSystem.jsonWriteFileSafe(filePath, buildAuctionSettingsPayload(), true)
  return true
end

local function loadAuctionSettings()
  auctionState.musicEnabled = true
  pendingSavedPreAuction = nil
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
  if type(data.preAuctionVehicle) == 'table' then
    local v = data.preAuctionVehicle
    if tonumber(v.px) and tonumber(v.py) and tonumber(v.pz) and
        tonumber(v.qx) and tonumber(v.qy) and tonumber(v.qz) and tonumber(v.qw) then
      pendingSavedPreAuction = v
    end
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

local function roundToNearestStep(value, step)
  local safeStep = math.max(1, tonumber(step) or 1)
  local normalized = math.max(0, tonumber(value) or 0) / safeStep
  return math.floor(normalized + 0.5) * safeStep
end

local function shuffleLotsAndAssignSpawnOrder(batch, spawnSpots, blockSpots)
  local n = #batch
  for i = n, 2, -1 do
    local j = math.random(i)
    batch[i], batch[j] = batch[j], batch[i]
  end
  local sc = #(spawnSpots or {})
  local bc = #(blockSpots or {})
  if sc <= 0 then
    return
  end
  for i, lot in ipairs(batch) do
    lot.lotIndex = i
    local si = ((i - 1) % sc) + 1
    lot.spawnSpot = spawnSpots[si]
    lot.blockSpot = (bc > 0) and blockSpots[((i - 1) % bc) + 1] or lot.spawnSpot
  end
end

local function buildPlayerConsignmentLot(sellerInventoryId)
  local veh = career_modules_inventory.getVehicle(sellerInventoryId)
  if not veh or not veh.model or type(veh.config) ~= 'table' then
    return nil
  end
  local cfgPath = veh.config.partConfigFilename
  if type(cfgPath) ~= 'string' or not FS:fileExists(cfgPath) then
    return nil
  end
  local mileageMeters = career_modules_inventory.setMileage(sellerInventoryId) or 0
  local mileageMi = math.max(0, math.floor(mileageMeters / 1609.344))
  local basePrice = career_modules_valueCalculator.getInventoryVehicleValue(sellerInventoryId) or 2000
  basePrice = math.max(500, math.floor(basePrice))
  local minStep = 250
  local startBid = math.max(minStep * 2, roundToNearestStep(basePrice * (0.55 + math.random() * 0.2), 500))
  local partCopy = nil
  if type(veh.partConditions) == 'table' then
    partCopy = deepCopy(veh.partConditions)
  end

  return {
    lotIndex = 0,
    spawnSpot = nil,
    blockSpot = nil,
    model = veh.model,
    config = veh.config,
    title = veh.niceName or 'Your vehicle',
    basePrice = basePrice,
    mileage = mileageMi,
    year = tonumber(veh.year) or (tonumber(os.date('%Y')) or 2026),
    minStep = minStep,
    currentBid = startBid,
    previewStartBid = startBid,
    highestBidder = 'npc',
    highestBidderName = 'NPC',
    leadingNpcPersonaId = nil,
    npcMaxBidsByPersonaId = {},
    npcPersonaNamesById = {},
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
    nextApproachControlAt = 0,
    sellerInventoryId = sellerInventoryId,
    playerListing = true,
    sellerPartConditions = partCopy,
    pricingInitialized = false
  }
end

local function setTriggerHidden(triggerName, hidden)
  local trigger = scenetree.findObject(triggerName)
  if trigger then
    trigger:setHidden(hidden and true or false)
  end
end

local function clearMarkerByName(markerName)
  local marker = scenetree.findObject(markerName)
  if not marker then
    return
  end

  if editor and editor.onRemoveSceneTreeObjects and marker.getID then
    pcall(function() editor.onRemoveSceneTreeObjects({marker:getID()}) end)
  end
  pcall(function() marker:delete() end)
end

local function clearAuctionExitMarker()
  clearMarkerByName(constants.AUCTION_EXIT_MARKER_NAME)
end

local function clearAuctionCounterMarker()
  clearMarkerByName(constants.AUCTION_COUNTER_MARKER_NAME)
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
  if auctionState.uiOpen then
    return
  end
  auctionState.uiOpen = true
  if extensions.overhaul_musicPlayer and extensions.overhaul_musicPlayer.loadMusicLibrary then
    extensions.overhaul_musicPlayer.loadMusicLibrary('/music', nil, true)
  end
  guihooks.trigger('UsedAuctionShow')
end

local function closeCounterOverlayUi()
  guihooks.trigger('UsedAuctionCounterHide')
end

local function closeAuctionOverlayUi()
  auctionState.uiOpen = false
  closeCounterOverlayUi()
  guihooks.trigger('UsedAuctionHide')
end

local function startFadeSafe()
  if ui_fadeScreen and ui_fadeScreen.start then
    ui_fadeScreen.start(constants.FADE_DURATION)
  end
end

local function stopFadeSafe()
  if ui_fadeScreen and ui_fadeScreen.stop then
    ui_fadeScreen.stop(constants.FADE_DURATION)
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
  clearAuctionCounterMarker()
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

local function roundAuctionMoney(amount)
  return math.max(0, math.floor((tonumber(amount) or 0) + 0.5))
end

local function clampCounterLotBatchSize(value)
  local minLots = constants.MIN_LOT_COUNT or 5
  local maxLots = constants.MAX_LOT_COUNT or minLots
  local lotCount = math.floor(tonumber(value) or constants.DEFAULT_LOT_COUNT or minLots)
  if lotCount < minLots then
    lotCount = minLots
  end
  if lotCount > maxLots then
    lotCount = maxLots
  end
  return lotCount
end

local function getCounterLotBatchMultiplier(lotCount)
  local minLots = constants.MIN_LOT_COUNT or 5
  local baseLots = constants.DEFAULT_LOT_COUNT or 10
  local maxLots = constants.MAX_LOT_COUNT or 25
  local safeLots = clampCounterLotBatchSize(lotCount)

  if safeLots <= baseLots then
    local lowSpan = math.max(1, baseLots - minLots)
    return 0.75 + ((safeLots - minLots) / lowSpan) * 0.25
  end

  local highSpan = math.max(1, maxLots - baseLots)
  return 1 + ((safeLots - baseLots) / highSpan)
end

local function getCounterOfferPricing(offer, lotCount)
  if type(offer) ~= 'table' then
    return nil
  end

  local safeLotCount = clampCounterLotBatchSize(lotCount)
  local rawCost = roundAuctionMoney((tonumber(offer.fullFee) or 0) * getCounterLotBatchMultiplier(safeLotCount))
  local creditRemaining = roundAuctionMoney(auctionState.entryCreditRemaining or 0)
  local creditApplied = math.min(rawCost, creditRemaining)
  local registrationFee = math.max(0, rawCost - creditApplied)

  return {
    lotCount = safeLotCount,
    rawCost = rawCost,
    creditApplied = creditApplied,
    registrationFee = registrationFee,
    remainingCreditAfter = math.max(0, creditRemaining - creditApplied)
  }
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

local function getCounterOfferById(typeId)
  if type(typeId) ~= 'string' or typeId == '' then
    return nil
  end

  for _, offer in ipairs(auctionState.counterOffers or {}) do
    if offer.id == typeId then
      return offer
    end
  end
end

local function getCounterRegistrationFeeForSelection(typeId, lotCount)
  local offer = getCounterOfferById(typeId)
  if not offer then
    return nil
  end
  local pricing = getCounterOfferPricing(offer, lotCount or auctionState.counterLotBatchSize)
  return pricing and pricing.registrationFee or nil
end

local function canAffordNextLotRegistration(typeId, lotCount)
  local fee = getCounterRegistrationFeeForSelection(typeId, lotCount)
  if fee == nil then
    return false
  end
  if fee <= 0 then
    return true
  end
  return canAfford(fee)
end

local function payNextLotRegistrationFee(typeId, lotCount, paymentLabel)
  local offer = getCounterOfferById(typeId)
  local pricing = offer and getCounterOfferPricing(offer, lotCount or auctionState.counterLotBatchSize) or nil
  if not pricing then
    return false
  end
  local fee = pricing.registrationFee
  if fee <= 0 then
    if pricing then
      auctionState.entryCreditRemaining = pricing.remainingCreditAfter
    end
    return true
  end

  local paid = payForVehicle(fee, paymentLabel or constants.AUCTION_LOT_REGISTRATION_PAYMENT_LABEL)
  if paid and pricing then
    auctionState.entryCreditRemaining = pricing.remainingCreditAfter
  end
  return paid
end

local function canRegisterMoreLots()
  return auctionState.phase == 'vaultIdle' or (auctionState.phase == 'complete' and not hasLiveTransitionLots())
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

local function tryApplyPendingSavedPreAuctionVehicle()
  if not pendingSavedPreAuction then
    return false
  end
  if not (career_career and career_career.isActive and career_career.isActive()) then
    return false
  end
  local veh = getPlayerVehicle()
  if not veh then
    return false
  end
  local v = pendingSavedPreAuction
  local px = tonumber(v.px)
  local py = tonumber(v.py)
  local pz = tonumber(v.pz)
  local qx = tonumber(v.qx)
  local qy = tonumber(v.qy)
  local qz = tonumber(v.qz)
  local qw = tonumber(v.qw)
  if not (px and py and pz and qx and qy and qz and qw) then
    pendingSavedPreAuction = nil
    saveAuctionSettings()
    return false
  end
  local pos = vec3(px, py, pz)
  local rot = quat(qx, qy, qz, qw)
  if spawn and spawn.safeTeleport then
    spawn.safeTeleport(veh, pos, rot)
  else
    veh:setPosRot(px, py, pz + 0.5, qx, qy, qz, qw)
  end
  if core_camera and core_camera.resetCamera then
    pcall(function() core_camera.resetCamera(0) end)
  end
  pendingSavedPreAuction = nil
  saveAuctionSettings()
  auctionState.entryCooldownUntil = getAuctionTime() + constants.ENTRY_RETRIGGER_COOLDOWN
  return true
end

local function getAuctionSaveRestoreSpot()
  local exitSpot = getPlayerExitSpot(auctionState.siteLayout, false)
  if exitSpot and exitSpot.pos and exitSpot.rot then
    return {
      pos = vec3(exitSpot.pos),
      rot = quat(0, 0, 1, 0) * quat(exitSpot.rot)
    }
  end

  local rt = auctionState.returnTransform
  if rt and rt.pos and rt.rot then
    return {
      pos = vec3(rt.pos),
      rot = quat(0, 0, 1, 0) * quat(rt.rot)
    }
  end
end

local function applyInventorySpawnOverrides(data)
  if auctionState.phase == 'idle' then
    return
  end
  local restoreSpot = getAuctionSaveRestoreSpot()
  if not restoreSpot then
    return
  end
  data.unicyclePos = vec3(restoreSpot.pos)
  local spawned = data.spawnedPlayerVehicles
  local cur = data.currentVehicle
  if not spawned or not cur or not spawned[cur] then
    return
  end
  spawned[cur] = {
    pos = vec3(restoreSpot.pos),
    rot = quat(restoreSpot.rot)
  }
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

local function getDefaultGearboxBehavior()
  local mode = settings and settings.getValue and settings.getValue('defaultGearboxBehavior') or nil
  if mode == 'realistic' or mode == 'arcade' then
    return mode
  end
  return 'arcade'
end

local function normalizePurchasedLotVehicleState(veh, lotIndex)
  if not veh then
    return false
  end

  stopVehicleAI(veh)
  setVehicleFreezeSafe(veh, true)

  if core_vehicleBridge and core_vehicleBridge.executeAction then
    pcall(function() core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', 0) end)
    pcall(function() core_vehicleBridge.executeAction(veh, 'setGearboxMode', getDefaultGearboxBehavior()) end)
  end

  veh:queueLuaCommand(string.format([[
    ai.setMode("stop")
    if electrics then
      electrics.setIgnitionLevel(0)
      if electrics.setLightsState then electrics.setLightsState(0) end
      if electrics.set_warn_signal then electrics.set_warn_signal(0) end
      if electrics.horn then electrics.horn(false) end
      local turnsignal = (electrics.values and electrics.values.turnsignal) or 0
      if turnsignal > 0 and electrics.toggle_right_signal then electrics.toggle_right_signal() end
      if turnsignal < 0 and electrics.toggle_left_signal then electrics.toggle_left_signal() end
    end
    input.event("parkingbrake", 1, 1)
    obj:queueGameEngineLua("career_modules_usedCarAuction.finalizePurchasedLot(%d)")
  ]], lotIndex))

  return true
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

getPlayerExitSpot = function(layout, warnOnFallback)
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

local function buildMarkerAtPos(markerName, markerPos, color, scale)
  if not markerPos then
    return false
  end

  local marker = createObject('TSStatic')
  marker:setField('shapeName', 0, constants.AUCTION_EXIT_MARKER_SHAPE)
  marker:setPosition(markerPos + vec3(0, 0, constants.AUCTION_EXIT_MARKER_Z_OFFSET))
  marker.scale = vec3(scale, scale, scale)
  marker:setField('rotation', 0, '1 0 0 0')
  marker.useInstanceRenderData = true
  marker:setField('instanceColor', 0, color)
  marker:setField('collisionType', 0, 'Collision Mesh')
  marker:setField('decalType', 0, 'Collision Mesh')
  marker:setField('allowPlayerStep', 0, '1')
  marker:setField('canSave', 0, '0')
  marker:setField('canSaveDynamicFields', 0, '1')
  marker.canSave = false
  marker:registerObject(markerName)
  if scenetree and scenetree.MissionGroup then
    scenetree.MissionGroup:addObject(marker)
  end

  return true
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

  return buildMarkerAtPos(
    constants.AUCTION_EXIT_MARKER_NAME,
    markerPos,
    constants.AUCTION_EXIT_MARKER_COLOR,
    constants.AUCTION_EXIT_MARKER_SCALE
  )
end

local function ensureAuctionCounterMarker()
  clearAuctionCounterMarker()

  local counterTrigger = scenetree.findObject(constants.AUCTION_COUNTER_MARKER_TRIGGER)
  if not counterTrigger then
    return false
  end

  local ok, pos = pcall(function() return counterTrigger:getPosition() end)
  if not ok or not pos then
    return false
  end

  return buildMarkerAtPos(
    constants.AUCTION_COUNTER_MARKER_NAME,
    vec3(pos),
    constants.AUCTION_COUNTER_MARKER_COLOR,
    constants.AUCTION_COUNTER_MARKER_SCALE
  )
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

local function getLotMileageMeters(lot)
  local mileageMiles = tonumber(lot and lot.mileage) or 0
  return math.max(0, math.floor(mileageMiles * 1609.344))
end

local function getCurrentYear()
  return tonumber(os.date('%Y')) or 2025
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

local function buildNextLotEntry(lotIndex)
  local layout = auctionState.siteLayout or {}
  return career_modules_usedCarAuctionLots.buildNextLotEntry(
    lotIndex,
    layout.spawnSpots or {},
    layout.blockSpots or {}
  )
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

local function getConfigKeyFromPath(configPath)
  if type(configPath) ~= 'string' then return nil end
  local normalized = configPath:gsub('\\', '/')
  local key = normalized:match('/configurations/([^/]+)%.pc$')
  if key then
    return key
  end
  return normalized:match('/([^/]+)%.pc$')
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
  local vehicleAge = math.max(0, getCurrentYear() - vehicleYear)
  local configKey = getConfigKeyFromPath(lot.config)

  return career_modules_valueCalculator.getVehicleCatalogIntrinsicBookValue({
    catalogBaseValue = baseValue,
    mileageMeters = mileageMeters,
    age = vehicleAge,
    modelName = lot.model,
    configKey = configKey,
    logContext = 'usedCarAuction',
    applyVehicleBuyMarket = true
  })
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

  career_modules_usedCarAuctionNpcs.repriceLot(lot, conditionedBase, auctionState.npcPersonas)
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

  if not lot.playerListing then
    pcall(function()
      applyRandomPaintToSpawnOptions(options, lot.model, lot.config)
    end)
  end

  local veh = core_vehicles.spawnNewVehicle(lot.model, options)
  if not veh then
    lot.state = 'failed'
    return false
  end

  if lot.playerListing and type(lot.sellerPartConditions) == 'table' then
    core_vehicleBridge.executeAction(veh, 'initPartConditions', lot.sellerPartConditions, 0, 1, 1)
  else
    core_vehicleBridge.executeAction(veh, 'initPartConditions', {}, getLotMileageMeters(lot), 1, 1)
  end
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
  auctionState.nextPlayerBidCheckAt = now + 0.5
  auctionState.nextLiveStatusAt = 0
  career_modules_usedCarAuctionNpcs.onLotBiddingBegin(lot, now, auctionState.npcPersonas)
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
  auctionState.rerollCounterOffersOnOpen = true
  setAuctionRunningTriggerState()
end

startLotByIndex = function(idx)
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

  local prevBid = lot.currentBid or 0
  lot.currentBid = bidAmount
  setPlayerAsLeader(lot)
  playBidAcceptedSound()
  maybeExtendLotTimer(lot)
  career_modules_usedCarAuctionNpcs.onPlayerBid(lot, bidAmount - prevBid)
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

hasLiveTransitionLots = function()
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
  if not hasGarageSpaceForPurchase() then
    setBidHint('No free garage slot. You cannot bid on vehicles.', 4)
    return false
  end
  if lot.sellerInventoryId or lot.playerListing then
    setBidHint("You can't bid on your own consignment.", 4)
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
  if not hasGarageSpaceForPurchase() then
    setBidHint('No free garage slot. You cannot bid on vehicles.', 4)
    return false
  end
  if lot.sellerInventoryId or lot.playerListing then
    setBidHint("You can't bid on your own consignment.", 4)
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

local function computeAuctionExitNeedsConfirm()
  return career_modules_inventory.getListedVehicleId() ~= nil
end

local function requestAuctionState()
  local now = getAuctionTime()
  local lotsOut = {}
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
      timeLeft = math.max(0, math.ceil((lot.endTime or 0) - now)),
      isPlayerListing = lot.sellerInventoryId ~= nil or lot.playerListing == true
    }
    table.insert(lotsOut, lotOut)
  end

  local derivedCurrentLot = nil
  local derivedCurrentLotIndex = nil
  local lots = auctionState.lots or {}
  for i, lot in ipairs(lots) do
    if lot.state == 'active' then
      derivedCurrentLot = lotsOut[i]
      derivedCurrentLotIndex = lot.lotIndex
      break
    end
  end
  if not derivedCurrentLot then
    for i, lot in ipairs(lots) do
      if lot.state == 'exiting' then
        derivedCurrentLot = lotsOut[i]
        derivedCurrentLotIndex = lot.lotIndex
        break
      end
    end
  end
  if not derivedCurrentLot then
    local activeIdx = tonumber(auctionState.activeLotIndex)
    local indexedLot = (activeIdx and activeIdx >= 1) and lotsOut[activeIdx] or nil
    if indexedLot and (indexedLot.state == 'queued' or indexedLot.state == 'approaching' or indexedLot.state == 'active' or indexedLot.state == 'exiting') then
      derivedCurrentLot = indexedLot
      derivedCurrentLotIndex = indexedLot.lotIndex
    end
  end
  if not derivedCurrentLot then
    for i, lot in ipairs(lots) do
      if lot.state == 'queued' or lot.state == 'approaching' or lot.state == 'active' or lot.state == 'exiting' then
        derivedCurrentLot = lotsOut[i]
        derivedCurrentLotIndex = lot.lotIndex
        break
      end
    end
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
  elseif derivedPhase == 'starting' then
    status = 'Entering the vault…'
  elseif derivedPhase == 'vaultIdle' then
    status = 'Go to the counter to start the auction.'
  elseif derivedPhase == 'bidding' then
    status = 'Auction in progress.'
  elseif derivedPhase == 'complete' then
    status = 'Go to the counter to start another auction.'
  end

  local mainAuctionPanelActive = (auctionState.phase == 'bidding') or hasLiveTransitionLots()
  local counterOffers = {}
  for _, offer in ipairs(auctionState.counterOffers or {}) do
    local pricing = getCounterOfferPricing(offer, auctionState.counterLotBatchSize) or {}
    local registrationFee = pricing.registrationFee or 0
    table.insert(counterOffers, {
      id = offer.id,
      label = offer.label,
      subtitle = offer.subtitle,
      tier = offer.tier,
      creditApplied = pricing.creditApplied or 0,
      registrationFee = registrationFee,
      coveredByEntry = registrationFee <= 0
    })
  end

  local phaseForTabs = auctionState.phase
  local counterShowAuctionsTab = not (phaseForTabs == 'bidding' or phaseForTabs == 'starting')
  local myVehicles = {}
  if auctionState.counterPromptActive then
    for invId, veh in pairs(career_modules_inventory.getVehicles()) do
      if veh.owned then
        local needsRepair = career_modules_insurance_insurance and
          career_modules_insurance_insurance.inventoryVehNeedsRepair(invId) or false
        table.insert(myVehicles, {
          inventoryId = invId,
          niceName = veh.niceName or 'Vehicle',
          value = career_modules_valueCalculator.getInventoryVehicleValue(invId) or 0,
          thumbnail = career_modules_inventory.getVehicleThumbnail(invId),
          listedForAuction = veh.listedForAuction and true or false,
          needsRepair = needsRepair and true or false
        })
      end
    end
    table.sort(myVehicles, function(a, b)
      return (a.niceName or '') < (b.niceName or '')
    end)
  end

  local listedVehicleInventoryId = career_modules_inventory.getListedVehicleId()
  local hasPlayerListingLotAtAuction = false
  for _, lot in ipairs(auctionState.lots or {}) do
    if lot.sellerInventoryId and lot.state ~= 'finished' and lot.state ~= 'failed' then
      hasPlayerListingLotAtAuction = true
      break
    end
  end
  local auctionExitNeedsConfirm = computeAuctionExitNeedsConfirm()

  return {
    phase = derivedPhase,
    entryPromptActive = auctionState.entryPromptActive and true or false,
    counterPromptActive = auctionState.counterPromptActive and true or false,
    musicEnabled = auctionState.musicEnabled ~= false,
    entryFee = getAuctionEntryFee(),
    canPayEntryFee = canAffordAuctionEntry(),
    canRegisterMoreLots = canRegisterMoreLots(),
    lotsRegisteredThisVisit = auctionState.lotsRegisteredThisVisit or 0,
    entryCreditRemaining = roundAuctionMoney(auctionState.entryCreditRemaining or 0),
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
    playerBalance = career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue("money") or 0,
    totalLots = #(auctionState.lots or {}),
    lots = lotsOut,
    counterOffers = counterOffers,
    mainAuctionPanelActive = mainAuctionPanelActive,
    lotBatchSize = clampCounterLotBatchSize(auctionState.counterLotBatchSize),
    counterShowAuctionsTab = counterShowAuctionsTab,
    myVehicles = myVehicles,
    listedVehicleInventoryId = listedVehicleInventoryId,
    hasPlayerListingLotAtAuction = hasPlayerListingLotAtAuction,
    auctionExitNeedsConfirm = auctionExitNeedsConfirm
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

local function closeMenuIfCounterOnly()
  if auctionState.phase ~= 'idle' then
    return
  end
  closeMenuUiOnly()
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

local function canUseAuctionCounter()
  return auctionState.phase == 'vaultIdle' or auctionState.phase == 'complete'
end

local function buildCounterOffer(tierConfig, baseOffer)
  local offer = {
    id = baseOffer.id,
    label = baseOffer.label,
    subtitle = baseOffer.subtitle,
    tier = tierConfig.tier,
    fullFee = tierConfig.fullFee
  }
  local pricing = getCounterOfferPricing(offer, auctionState.counterLotBatchSize) or {}
  offer.creditApplied = pricing.creditApplied or 0
  offer.registrationFee = pricing.registrationFee or 0
  offer.coveredByEntry = offer.registrationFee <= 0
  return offer
end

local function setCounterLotBatchSize(lotCount)
  auctionState.counterLotBatchSize = clampCounterLotBatchSize(lotCount)
  for _, offer in ipairs(auctionState.counterOffers or {}) do
    local pricing = getCounterOfferPricing(offer, auctionState.counterLotBatchSize) or {}
    offer.creditApplied = pricing.creditApplied or 0
    offer.registrationFee = pricing.registrationFee or 0
    offer.coveredByEntry = offer.registrationFee <= 0
  end
  return auctionState.counterLotBatchSize
end

local function rollCounterOffers()
  auctionState.counterOffers = {}

  for tierIndex, tierConfig in ipairs(auctionCounterTypeTiers) do
    local tierOffers = tierConfig.offers or {}
    if #tierOffers > 0 then
      local picked
      if tierIndex == 1 and career_modules_inventory.getListedVehicleId() then
        for _, o in ipairs(tierOffers) do
          if o.id == 'anything_goes' then
            picked = o
            break
          end
        end
        picked = picked or tierOffers[1]
      else
        picked = tierOffers[math.random(1, #tierOffers)]
      end
      table.insert(auctionState.counterOffers, buildCounterOffer(tierConfig, picked))
    end
  end
end

local function openCounterPrompt()
  if auctionState.transitionActive then
    return false
  end
  local ph = auctionState.phase
  if not (ph == 'vaultIdle' or ph == 'complete' or ph == 'bidding' or ph == 'starting') then
    return false
  end
  auctionState.counterLotBatchSize = clampCounterLotBatchSize(constants.DEFAULT_LOT_COUNT)
  local co = auctionState.counterOffers or {}
  if auctionState.rerollCounterOffersOnOpen or #co < 1 then
    rollCounterOffers()
    auctionState.rerollCounterOffersOnOpen = false
  end
  auctionState.counterPromptActive = true
  openMenu()
  guihooks.trigger('UsedAuctionCounterShow')
  return true
end

local function cancelCounterPrompt(closeUi)
  if not auctionState.counterPromptActive then
    if closeUi then
      closeMenuIfCounterOnly()
    end
    return false
  end

  auctionState.counterPromptActive = false
  closeCounterOverlayUi()
  if closeUi then
    closeMenuIfCounterOnly()
  end
  return true
end

local function clearLotsForNextBatch()
  for _, lot in ipairs(auctionState.lots or {}) do
    if lot.vehId and not lot.wonInventoryId then
      deleteVehicleSafe(lot.vehId)
    end
  end

  auctionState.lots = {}
  auctionState.activeLotIndex = 1
  auctionState.awaitingFinalExit = false
  auctionState.nextPlayerBidCheckAt = 0
  auctionState.nextLiveStatusAt = 0
  auctionState.bidHint = nil
  auctionState.bidHintUntil = 0
end

local function queueNextLotBatch(selectedTypeId, requestedLotCount)
  if not canUseAuctionCounter() then
    return false
  end
  if auctionState.transitionActive then
    return false
  end
  if not hasGarageSpaceForPurchase() then
    return false
  end
  if not canRegisterMoreLots() then
    return false
  end
  local selectedOffer = getCounterOfferById(selectedTypeId)
  if not selectedOffer then
    return false
  end
  local lotCount = clampCounterLotBatchSize(requestedLotCount)
  if not canAffordNextLotRegistration(selectedTypeId, lotCount) then
    return false
  end
  local auctionFilter = career_modules_usedCarAuctionLots.composeAuctionTypeFilter(selectedTypeId)
  if type(auctionFilter) ~= 'table' then
    return false
  end

  local layout = auctionState.siteLayout or {}
  local spawnSpots = layout.spawnSpots or {}
  local blockSpots = layout.blockSpots or {}
  local sellerInvId = career_modules_inventory.getListedVehicleId()
  local injectPlayer = selectedTypeId == 'anything_goes' and sellerInvId
  local lotBatch

  if injectPlayer then
    local playerLot = buildPlayerConsignmentLot(sellerInvId)
    if not playerLot then
      return false
    end
    career_modules_usedCarAuctionLots.resetUsedConfigs()
    local remainder = lotCount - 1
    if remainder > 0 then
      lotBatch = career_modules_usedCarAuctionLots.buildLotBatch(1, remainder, spawnSpots, blockSpots, auctionFilter)
    else
      lotBatch = {}
    end
    if type(lotBatch) ~= 'table' then
      lotBatch = {}
    end
    table.insert(lotBatch, playerLot)
    shuffleLotsAndAssignSpawnOrder(lotBatch, spawnSpots, blockSpots)
  else
    lotBatch = career_modules_usedCarAuctionLots.buildLotBatch(1, lotCount, spawnSpots, blockSpots, auctionFilter)
  end

  if type(lotBatch) ~= 'table' or #lotBatch < 1 then
    return false
  end

  local payCount = #lotBatch
  local paymentLabel = string.format('%s (%s, %d Lots)', constants.AUCTION_LOT_REGISTRATION_PAYMENT_LABEL, selectedOffer.label, payCount)

  clearLotsForNextBatch()
  auctionState.lots = lotBatch

  local npcModule = career_modules_usedCarAuctionNpcs
  auctionState.npcPersonas = npcModule.generatePersonas(#auctionState.lots)
  npcModule.initSession({
    getAuctionTime = getAuctionTime,
    commitNpcBid = function(lot, persona, increment)
      lot.currentBid = lot.currentBid + increment
      setNpcAsLeader(lot, persona)
      playBidAcceptedSound()
      maybeExtendLotTimer(lot)
      showLiveAuctionStatus(true)
    end
  }, auctionState.npcPersonas, auctionState.lots)

  auctionState.activeLotIndex = 0
  auctionState.awaitingFinalExit = false
  local started = startNextLotAfter(0)
  if not started then
    clearLotsForNextBatch()
    npcModule.resetSession()
    auctionState.awaitingFinalExit = false
    return false
  end

  if not payNextLotRegistrationFee(selectedTypeId, payCount, paymentLabel) then
    for _, lot in ipairs(auctionState.lots or {}) do
      if lot.vehId and not lot.wonInventoryId then
        deleteVehicleSafe(lot.vehId)
      end
    end
    clearLotsForNextBatch()
    npcModule.resetSession()
    auctionState.phase = 'vaultIdle'
    return false
  end

  auctionState.lotsRegisteredThisVisit = (auctionState.lotsRegisteredThisVisit or 0) + 1
  auctionState.phase = 'bidding'
  return true
end

local function confirmRegisterNextLot(selectedTypeId, lotCount)
  if not auctionState.counterPromptActive then
    return false
  end

  local queued = queueNextLotBatch(selectedTypeId, lotCount)
  if not queued then
    return false
  end

  auctionState.counterPromptActive = false
  closeCounterOverlayUi()
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
  if auctionState.counterPromptActive then
    return cancelCounterPrompt(true)
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
  career_modules_usedCarAuctionNpcs.onLotEnd(lot, auctionState.npcPersonas)

  if lot.highestBidder == 'player' and lot.sellerInventoryId then
    career_modules_inventory.clearVehicleAuctionListing(lot.sellerInventoryId)
    beginLotExit(lot)
    startNextLotAfter(lot.lotIndex)
    return
  end

  if lot.highestBidder == 'npc' and lot.sellerInventoryId then
    local salePrice = tonumber(lot.currentBid) or 0
    if salePrice > 0 then
      career_modules_payment.reward(
        { money = { amount = salePrice } },
        { label = string.format('Auction sale: %s', lot.title or 'Vehicle'), tags = { 'auctionSale' } },
        true
      )
    end
    career_modules_inventory.clearVehicleAuctionListing(lot.sellerInventoryId)
    career_modules_inventory.removeVehicle(lot.sellerInventoryId)
    beginLotExit(lot)
    startNextLotAfter(lot.lotIndex)
    return
  end

  if lot.highestBidder == 'player' then
    if not hasGarageSpaceForPurchase() then
    elseif canAfford(lot.currentBid) then
      payForVehicle(lot.currentBid, string.format('Used Auction: %s', lot.title))
      local veh = lot.vehId and getObjectByID(lot.vehId)
      if veh and normalizePurchasedLotVehicleState(veh, lot.lotIndex) then
        return
      end

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

local function finalizePurchasedLot(lotIndex)
  local lot = auctionState.lots and auctionState.lots[tonumber(lotIndex or 0)]
  if not lot then
    return false
  end
  if lot.sellerInventoryId then
    return false
  end

  local inventoryId = career_modules_inventory.addVehicle(lot.vehId, nil, {owned = true})
  if inventoryId then
    if not career_modules_inventory.moveVehicleToGarage(inventoryId) then
      career_modules_inventory.removeVehicle(inventoryId)
      beginLotExit(lot)
      startNextLotAfter(lot.lotIndex)
      return false
    end
    lot.wonByPlayer = true
    lot.wonInventoryId = inventoryId
    table.insert(auctionState.purchasedInventoryIds, inventoryId)
    playLotWinCelebrationSound()
    triggerAuctionWinEmitters(constants.LOT_WIN_EMITTER_DURATION)
  end

  beginLotExit(lot)
  startNextLotAfter(lot.lotIndex)
  return true
end

local function resetAuction(keepPurchases)
  closeAuctionOverlayUi()
  clearAuctionExitMarker()
  clearAuctionCounterMarker()

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
  auctionState.nextPlayerBidCheckAt = 0
  auctionState.nextLiveStatusAt = 0
  auctionState.noSpaceWarnCooldownUntil = 0
  auctionState.switchWarnCooldownUntil = 0
  auctionState.lastValidPlayerVehId = nil
  auctionState.entryPromptActive = false
  auctionState.counterPromptActive = false
  auctionState.counterOffers = {}
  auctionState.rerollCounterOffersOnOpen = false
  auctionState.counterLotBatchSize = clampCounterLotBatchSize(constants.DEFAULT_LOT_COUNT)
  auctionState.entryCreditRemaining = 0
  auctionState.awaitingFinalExit = false
  auctionState.npcPersonas = {}
  auctionState.lotsRegisteredThisVisit = 0
  career_modules_usedCarAuctionNpcs.resetSession()
  career_modules_usedCarAuctionLots.resetUsedConfigs()
  auctionState.winEmitterPulseToken = (auctionState.winEmitterPulseToken or 0) + 1
  setAuctionWinEmittersEnabled(false)
  setAuctionActiveAssetsEnabled(false)

  auctionState.purchasedInventoryIds = {}
  auctionState.bidHint = nil
  auctionState.bidHintUntil = 0

  setIdleTriggerState()
  saveAuctionSettings()
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
  auctionState.counterPromptActive = false
  auctionState.counterLotBatchSize = clampCounterLotBatchSize(constants.DEFAULT_LOT_COUNT)
  auctionState.entryCreditRemaining = roundAuctionMoney(getAuctionEntryFee())
  auctionState.returnTransform = {
    pos = playerVeh:getPosition(),
    rot = quat(playerVeh:getRefNodeRotation())
  }
  career_modules_usedCarAuctionLots.resetUsedConfigs()

  runFadedTransition(function()
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
    ensureAuctionCounterMarker()

    local npcModule = career_modules_usedCarAuctionNpcs
    auctionState.lots = {}
    auctionState.lotsRegisteredThisVisit = 0
    auctionState.counterOffers = {}
    auctionState.rerollCounterOffersOnOpen = false
    auctionState.counterLotBatchSize = clampCounterLotBatchSize(constants.DEFAULT_LOT_COUNT)
    auctionState.npcPersonas = npcModule.generatePersonas(constants.DEFAULT_LOT_COUNT)
    npcModule.initSession({
      getAuctionTime = getAuctionTime,
      commitNpcBid = function(lot, persona, increment)
        lot.currentBid = lot.currentBid + increment
        setNpcAsLeader(lot, persona)
        playBidAcceptedSound()
        maybeExtendLotTimer(lot)
        showLiveAuctionStatus(true)
      end
    }, auctionState.npcPersonas, {})
    auctionState.activeLotIndex = 0
    auctionState.awaitingFinalExit = false
    auctionState.phase = 'vaultIdle'
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

local function listVehicleForNextAnythingGoesAuction(inventoryId)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return false
  end
  local veh = career_modules_inventory.getVehicle(inventoryId)
  if not veh or not veh.owned then
    return false
  end
  return career_modules_inventory.setVehicleListedForAuction(inventoryId, true)
end

local function cancelAuctionListing(inventoryId)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return false
  end
  for _, lot in ipairs(auctionState.lots or {}) do
    if lot.sellerInventoryId == inventoryId and lot.state ~= 'finished' and lot.state ~= 'failed' then
      return false
    end
  end
  career_modules_inventory.clearVehicleAuctionListing(inventoryId)
  return true
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

  local isWalking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()

  if data.triggerName and data.triggerName:find(constants.ENTRY_TRIGGER) then
    if not isWalking then
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

  if data.triggerName and data.triggerName:find(constants.COUNTER_TRIGGER_PREFIX, 1, true) then
    if not isWalking then
      return
    end

    openCounterPrompt()
    return
  end

  if data.triggerName and data.triggerName:find(constants.EXIT_TRIGGER) then
    if auctionState.phase ~= 'idle' then
      if computeAuctionExitNeedsConfirm() then
        guihooks.trigger('UsedAuctionExitRequest')
      else
        exitAuctionArea()
      end
    end
  end
end

local function onUpdate(_, dtSim)
  advanceAuctionTime(dtSim)
  tryApplyPendingSavedPreAuctionVehicle()
  if auctionState.phase ~= 'bidding' then
    return
  end
  local now = getAuctionTime()

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

  career_modules_usedCarAuctionNpcs.tick(lot, dtSim, auctionState.npcPersonas)
end

local function hideAuctionUiAndDisableAssets()
  hardDisableAuctionAudioVisuals()
  auctionState.uiOpen = false
  closeCounterOverlayUi()
  guihooks.trigger('UsedAuctionHide')
end

local function onCareerActivated()
  loadAuctionSettings()
  setIdleTriggerState()
  hideAuctionUiAndDisableAssets()
  if not tryApplyPendingSavedPreAuctionVehicle() then
    ejectPlayerFromAuctionInteriorOnCareerLoad()
  end
end

local function onSaveCurrentSaveSlot(currentSavePath)
  saveAuctionSettings(currentSavePath)
end

local function onSetupInventoryFinished()
  tryApplyPendingSavedPreAuctionVehicle()
end

local function onCareerDeactivatedWhileLevelLoaded()
  closeCounterOverlayUi()
  guihooks.trigger('UsedAuctionHide')
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
M.onSetupInventoryFinished = onSetupInventoryFinished
M.applyInventorySpawnOverrides = applyInventorySpawnOverrides
M.exitAuctionArea = exitAuctionArea
M.listVehicleForNextAnythingGoesAuction = listVehicleForNextAnythingGoesAuction
M.cancelAuctionListing = cancelAuctionListing
M.requestAuctionState = requestAuctionState
M.startAuction = startAuction
M.cancelTravelPrompt = cancelTravelPrompt
M.cancelCounterPrompt = cancelCounterPrompt
M.confirmRegisterNextLot = confirmRegisterNextLot
M.setCounterLotBatchSize = setCounterLotBatchSize
M.placeBid = placeBid
M.passCurrentLot = passCurrentLot
M.setAutoBidEnabled = setAutoBidEnabled
M.setAutoBidMax = setAutoBidMax
M.setAuctionMusicEnabled = setAuctionMusicEnabled
M.finalizePurchasedLot = finalizePurchasedLot
M.closeMenu = closeMenu

return M
