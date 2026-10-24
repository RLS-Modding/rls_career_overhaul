-- Used-car auction owner: the vault's state and saved settings, entry and registration payments, the trigger and lifecycle hooks, and the parts they drive.
-- Notable: the state table is created once and reset in place; sessions and lot parts get copy and reset helpers from here.

local constants = require('overhaul/career/market/auction/constants')
local bidding = require('overhaul/career/market/auction/bidding')
local flow = require('overhaul/career/market/auction/flow')
local motion = require('overhaul/career/market/auction/motion')
local presentation = require('overhaul/career/market/auction/presentation')
local pricing = require('overhaul/career/market/auction/pricing')
local registration = require('overhaul/career/market/auction/registration')
local session = require('overhaul/career/market/auction/session')
local site = require('overhaul/career/market/auction/site')
local vehicleControl = require('overhaul/career/market/auction/vehicleControl')
local view = require('overhaul/career/market/auction/view')
local statePush = require('overhaul/lib/ui/statePush')

local M = {}

M.dependencies = {'gameplay_sites_sitesManager', 'util_configListGenerator'}

-- Auction state -----------------------------------------------------------------------------------

-- Deep copy of plain lot and vehicle data, so auction records never share tables with inventory.
local function copyTable(source)
  if type(source) ~= 'table' then return source end
  local out = {}
  for key, value in pairs(source) do
    out[key] = copyTable(value)
  end
  return out
end

-- Visit fields a reset gives back their defaults; the clock, cooldown, UI, music and tokens survive.
local function assignVisitDefaults(state)
  state.phase = 'idle'
  state.lots = {}
  state.activeLotIndex = 1
  state.siteLayout = nil
  state.returnTransform = nil
  state.auctionSpot = nil
  state.travelSpot = nil
  state.nextLiveStatusAt = 0
  state.switchWarnCooldownUntil = 0
  state.lastValidPlayerVehId = nil
  state.entryPromptActive = false
  state.counterPromptActive = false
  state.counterOffers = {}
  state.rerollCounterOffersOnOpen = false
  state.counterLotBatchSize = pricing.clampLotBatchSize(constants.DEFAULT_LOT_COUNT)
  state.entryCreditRemaining = 0
  state.awaitingFinalExit = false
  state.npcPersonas = {}
  state.lotsRegisteredThisVisit = 0
end

local function assignFinalVisitDefaults(state)
  state.purchasedInventoryIds = {}
  state.bidHint = nil
  state.bidHintUntil = 0
end

-- Creates the state, or resets `existing` in place and returns it. Pass the existing table on every reset.
local function newAuctionState(existing, deferFinalFields)
  local state = existing or {
    simTime = 0,
    transitionActive = false,
    entryCooldownUntil = 0,
    uiOpen = false,
    musicEnabled = true,
    winEmitterPulseToken = 0,
  }
  assignVisitDefaults(state)
  if not deferFinalFields then assignFinalVisitDefaults(state) end
  return state
end

-- Cleanup operations must still see the visit's purchases and hint until asset shutdown finishes.
local function finishAuctionReset(state)
  assignFinalVisitDefaults(state)
  -- Reset owns the final HUD event; idle frames never need to publish it.
  statePush.send('UsedAuctionState', {sessionActive = false})
end

local auctionState = newAuctionState()
-- Freeze and transit callbacks are keyed by vehicle id; the parts share these tables.
local pendingFreezeTokens = {}
local pendingTransitCallbacks = {}
local pendingSavedPreAuction = nil

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

-- Payments ----------------------------------------------------------------------------------------

-- The entry fee and lot registration fees go through the career payment ledger and are refundable
-- until the entry or registration is confirmed.
local function canAfford(amount)
  return overhaul_career_economy_payment.canPay({
    money = {
      amount = amount,
      canBeNegative = false
    }
  })
end

local function pay(amount, label, category, finance, onRecorded)
  return overhaul_career_economy_payment.pay({
    money = {
      amount = amount,
      canBeNegative = false
    }
  }, require("overhaul/lib/finance/metadata").tag({
    label = label,
    tags = {'usedAuction'}
  }, category or "service", finance), nil, onRecorded) ~= false
end

local function refund(amount, label, finance)
  amount = tonumber(amount) or 0
  if amount <= 0 then return end
  overhaul_career_economy_payment.reward({ money = { amount = amount } }, require("overhaul/lib/finance/metadata").tag({
    label = label,
    tags = {'usedAuction', 'refund'}
  }, "refund", finance), true)
end

local function getEntryFee()
  return tonumber(constants.AUCTION_ENTRY_FEE_DOLLARS) or 0
end

local function canAffordEntry()
  local fee = getEntryFee()
  if fee <= 0 then
    return true
  end
  return canAfford(fee)
end

local function payEntryFee()
  local fee = getEntryFee()
  if fee <= 0 then
    return true
  end

  if not pay(fee, string.format('Used Auction Entry ($%d)', fee)) then
    return false
  end
  auctionState.entryFeeRefundable = fee
  return true
end

local function refundEntryFee()
  local fee = tonumber(auctionState.entryFeeRefundable) or 0
  auctionState.entryFeeRefundable = nil
  if fee > 0 then
    refund(fee, string.format('Used Auction Entry refund ($%d)', fee))
  end
end

-- Price of a lot batch against a counter offer, after entry credit; nil for an unknown offer.
local function registrationQuote(typeId, lotCount)
  local offer = pricing.findCounterOffer(auctionState.counterOffers, typeId)
  if not offer then
    return nil
  end
  return pricing.counterOfferPricing(offer, lotCount or auctionState.counterLotBatchSize, auctionState.entryCreditRemaining)
end

local function canAffordLotRegistration(typeId, lotCount)
  local quote = registrationQuote(typeId, lotCount)
  local fee = quote and quote.registrationFee or nil
  if fee == nil then
    return false
  end
  if fee <= 0 then
    return true
  end
  return canAfford(fee)
end

local function payLotRegistration(typeId, lotCount, paymentLabel)
  local quote = registrationQuote(typeId, lotCount)
  if not quote then
    return false
  end
  local fee = quote.registrationFee
  if fee <= 0 then
    auctionState.entryCreditRemaining = quote.remainingCreditAfter
    return true
  end

  local paid = pay(fee, paymentLabel or constants.AUCTION_LOT_REGISTRATION_PAYMENT_LABEL)
  if paid then
    auctionState.entryCreditRemaining = quote.remainingCreditAfter
  end
  return paid
end

-- The parts, in dependency order: each sees only the parts created before it.
local parts = {}
local function publishAuctionState(force)
  local send = force == false and statePush.refresh or statePush.send
  send('UsedAuctionState', parts.view.requestAuctionHudState())
end
parts.motion = motion.create()
parts.vehicleControl = vehicleControl.create({
  auctionState = auctionState,
  pendingFreezeTokens = pendingFreezeTokens,
  pendingTransitCallbacks = pendingTransitCallbacks,
  stopVehicleAI = parts.motion.stopVehicleAI,
})
parts.site = site.create()
parts.presentation = presentation.create({
  auctionState = auctionState,
  pendingFreezeTokens = pendingFreezeTokens,
  pendingTransitCallbacks = pendingTransitCallbacks,
  site = parts.site,
  vehicleControl = parts.vehicleControl,
})
parts.payments = {
  canAfford = canAfford,
  pay = pay,
  refund = refund,
  getEntryFee = getEntryFee,
  canAffordEntry = canAffordEntry,
  payEntryFee = payEntryFee,
  refundEntryFee = refundEntryFee,
  canAffordLotRegistration = canAffordLotRegistration,
  payLotRegistration = payLotRegistration,
}
parts.bidding = bidding.create({
  publishState = publishAuctionState,
  auctionState = auctionState,
  copyTable = copyTable,
  getAuctionTime = getAuctionTime,
  motion = parts.motion,
  payments = parts.payments,
  pendingFreezeTokens = pendingFreezeTokens,
  presentation = parts.presentation,
  vehicleControl = parts.vehicleControl,
})
parts.session = session.create({
  auctionState = auctionState,
  bidding = parts.bidding,
  finishAuctionReset = finishAuctionReset,
  newAuctionState = newAuctionState,
  getAuctionTime = getAuctionTime,
  motion = parts.motion,
  payments = parts.payments,
  presentation = parts.presentation,
  site = parts.site,
  vehicleControl = parts.vehicleControl,
})
parts.registration = registration.create({
  auctionState = auctionState,
  bidding = parts.bidding,
  copyTable = copyTable,
  getAuctionTime = getAuctionTime,
  payments = parts.payments,
  presentation = parts.presentation,
  vehicleControl = parts.vehicleControl,
})
parts.flow = flow.create({
  auctionState = auctionState,
  bidding = parts.bidding,
  payments = parts.payments,
  presentation = parts.presentation,
  session = parts.session,
  site = parts.site,
})
parts.view = view.create({
  auctionState = auctionState,
  bidding = parts.bidding,
  getAuctionTime = getAuctionTime,
  payments = parts.payments,
  registration = parts.registration,
})

-- Saved settings ----------------------------------------------------------------------------------

local function getAuctionSettingsPaths(currentSavePath)
  if not currentSavePath then
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
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
    local returnTransform = auctionState.returnTransform
    local pos, rot = returnTransform.pos, returnTransform.rot
    if pos and rot then
      local savedRot = quat(0, 0, 1, 0) * quat(rot)
      payload.preAuctionVehicle = {
        px = pos.x, py = pos.y, pz = pos.z,
        qx = savedRot.x, qy = savedRot.y, qz = savedRot.z, qw = savedRot.w
      }
    end
  end
  return payload
end

local function saveAuctionSettings(currentSavePath, writer)
  if not currentSavePath then
    return false
  end

  local dirPath, filePath = getAuctionSettingsPaths(currentSavePath)
  if not filePath then
    return false
  end

  if not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end

  overhaul_career_saveSystem.jsonWriteFileSafe(filePath, buildAuctionSettingsPayload(), true)
  return true
end

-- Mission and POI hooks can run before career has loaded its extension.
local function loadAuctionSettings()
  auctionState.musicEnabled = true
  pendingSavedPreAuction = nil
  if not overhaul_career_career or not overhaul_career_career.isActive() then
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
    local savedVehicle = data.preAuctionVehicle
    if tonumber(savedVehicle.px) and tonumber(savedVehicle.py) and tonumber(savedVehicle.pz) and
        tonumber(savedVehicle.qx) and tonumber(savedVehicle.qy) and tonumber(savedVehicle.qz) and tonumber(savedVehicle.qw) then
      pendingSavedPreAuction = savedVehicle
    end
  end
  return true
end

-- Puts the player back where they stood before the vault, once the saved position can be applied.
local function tryApplyPendingSavedPreAuctionVehicle()
  if not pendingSavedPreAuction then
    return false
  end
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return false
  end
  local veh = be:getPlayerVehicle(0)
  if not veh then
    return false
  end
  local savedVehicle = pendingSavedPreAuction
  local px = tonumber(savedVehicle.px)
  local py = tonumber(savedVehicle.py)
  local pz = tonumber(savedVehicle.pz)
  local qx = tonumber(savedVehicle.qx)
  local qy = tonumber(savedVehicle.qy)
  local qz = tonumber(savedVehicle.qz)
  local qw = tonumber(savedVehicle.qw)
  if not (px and py and pz and qx and qy and qz and qw) then
    pendingSavedPreAuction = nil
    return false
  end
  local pos = vec3(px, py, pz)
  local rot = quat(qx, qy, qz, qw)
  spawn.safeTeleport(veh, pos, rot)
  core_camera.resetCamera(0)
  pendingSavedPreAuction = nil
  auctionState.entryCooldownUntil = getAuctionTime() + constants.ENTRY_RETRIGGER_COOLDOWN_S
  return true
end

local function getAuctionSaveRestoreSpot()
  local returnTransform = auctionState.returnTransform
  if returnTransform and returnTransform.pos and returnTransform.rot then
    return {
      pos = vec3(returnTransform.pos),
      rot = quat(0, 0, 1, 0) * quat(returnTransform.rot)
    }
  end

  local exitSpot = parts.site.getPlayerExitSpot(auctionState.siteLayout, false)
  if exitSpot and exitSpot.pos and exitSpot.rot then
    return {
      pos = vec3(exitSpot.pos),
      rot = quat(0, 0, 1, 0) * quat(exitSpot.rot)
    }
  end
end

-- Inventory data saved during a visit points the player's car at the restore spot.
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
  if not spawned or not cur then
    return
  end
  local key = spawned[cur] and cur or tostring(cur)
  if not spawned[key] then
    return
  end
  spawned[key] = {
    pos = vec3(restoreSpot.pos),
    rot = quat(restoreSpot.rot)
  }
end

-- Consignment -------------------------------------------------------------------------------------

local function isAuctionLotVehicleId(vehId)
  if not vehId then return false end
  for _, lot in ipairs(auctionState.lots or {}) do
    if lot and lot.vehId == vehId then
      return true
    end
  end
  return false
end

local function listVehicleForNextAnythingGoesAuction(inventoryId)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return false
  end
  local veh = overhaul_career_garage_inventory.getVehicle(inventoryId)
  if not veh or not veh.owned then
    return false
  end
  if veh.listedForAuction then return true end
  local completed = false
  local function onComplete()
    if completed then return end
    completed = true
    auctionState.rerollCounterOffersOnOpen = true
    overhaul_career_saveSystem.saveCurrent()
  end
  local listed = overhaul_career_garage_inventory.setVehicleListedForAuction(inventoryId, true, onComplete)
  if listed then onComplete() end
  return listed
end

local function cancelAuctionListing(inventoryId)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return false
  end
  local veh = overhaul_career_garage_inventory.getVehicle(inventoryId)
  local inventory = overhaul_career_garage_inventory
  local pending = inventory.isAuctionListingPending and inventory.isAuctionListingPending(inventoryId)
  if not veh or (not veh.listedForAuction and not pending) then return false end
  for _, lot in ipairs(auctionState.lots or {}) do
    if lot.sellerInventoryId == inventoryId and lot.state ~= 'finished' and lot.state ~= 'failed' then
      return false
    end
  end
  overhaul_career_garage_inventory.clearVehicleAuctionListing(inventoryId)
  auctionState.rerollCounterOffersOnOpen = true
  overhaul_career_saveSystem.saveCurrent()
  return true
end

-- Vehicle switching -------------------------------------------------------------------------------

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
  auctionState.switchWarnCooldownUntil = now + constants.VEHICLE_SWITCH_REJECT_WARN_COOLDOWN_S
end

local function onVehicleSwitched(oldId, newId)
  if not overhaul_career_career or not overhaul_career_career.isActive() then return end
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

  core_jobsystem.create(function(job)
    job.sleep(constants.VEHICLE_SWITCH_REVERT_DELAY_S)
    local fallbackVeh = getObjectByID(fallbackVehId)
    if fallbackVeh then
      be:enterVehicle(0, fallbackVeh)
    end
  end)
end

-- Lot loop ----------------------------------------------------------------------------------------

-- Whether a lot car has parked on its block: horizontal distance and speed within the arrival limits.
local function lotArrivedAtBlock(lot, lotVeh)
  if not lotVeh then return false end
  if lotVeh:getDirectionVectorUp().z < 0.5 then return false end
  local blockSpot = lot.blockSpot or lot.spawnSpot
  if not blockSpot then return false end
  -- Parking precision is horizontal: the reference-node height varies with configuration and load.
  local blockDelta = lotVeh:getPosition() - vec3(blockSpot.pos)
  if math.abs(blockDelta.z) > 2 then return false end
  blockDelta.z = 0
  local distToBlock = blockDelta:length()
  local speed = lotVeh:getVelocity():length()
  local facing = lotVeh:getDirectionVector():z0():normalized()
  local targetFacing = (quat(blockSpot.rot) * vec3(0, 1, 0)):z0():normalized()
  return distToBlock <= constants.LOT_ARRIVE_DISTANCE_M and speed <= constants.LOT_ARRIVE_SPEED_MPS
    and facing:dot(targetFacing) >= constants.LOT_ARRIVE_HEADING_DOT
end

local function lotExitIsDone(lotVeh)
  if not lotVeh then
    return true
  end
  local despawnSpot = auctionState.siteLayout and auctionState.siteLayout.despawnSpot
  if not despawnSpot then
    return false
  end
  local dist = (lotVeh:getPosition() - vec3(despawnSpot.pos)):length()
  return dist <= constants.LOT_EXIT_DESPAWN_DISTANCE_M
end

local function lotIsStuck(lot, now)
  return now - (lot.lastMotionAt or now) >= constants.LOT_STUCK_TIMEOUT_S
    or now - (lot.driveStartedAt or now) >= constants.LOT_TRANSIT_TIMEOUT_S
end

-- A car on its way to the block starts bidding once it parks there, or when it has stopped making progress.
local function tickApproachingLot(lot, now)
  if lot.recoveryPending then return end
  local lotVeh = lot.vehId and getObjectByID(lot.vehId)
  parts.bidding.refreshLotMotionProgress(lot, lotVeh, now)
  if lotArrivedAtBlock(lot, lotVeh) then
    parts.bidding.beginLotBidding(lot)
  elseif (lotVeh and lotVeh:getDirectionVectorUp().z < 0.5) or lotIsStuck(lot, now) then
    -- A rollover may still move towards the target. Do not count that as a
    -- healthy approach, or freeze an upside-down car as an arrived lot.
    parts.bidding.recoverLotApproach(lot)
  end
end

-- A car leaving the block is despawned at the despawn spot, or when it has stopped making progress.
local function tickExitingLot(lot, now)
  if lot.exitCleanupPending then return end
  local lotVeh = lot.vehId and getObjectByID(lot.vehId)
  parts.bidding.refreshLotMotionProgress(lot, lotVeh, now)
  local done = lotExitIsDone(lotVeh)

  if done or lotIsStuck(lot, now) then
    parts.bidding.completeLotExit(lot, not done)
  end
end

local function onUpdate(dtReal, dtSim)
  -- Idle sessions have no HUD to refresh and must not scan garage inventory.
  if auctionState.phase ~= 'idle' then
    -- Real time keeps the passive HUD correct even while the player pauses.
    auctionState.hudElapsed = (auctionState.hudElapsed or 0) + (dtReal or 0)
    if auctionState.hudElapsed >= constants.HUD_UPDATE_INTERVAL_S then
      auctionState.hudElapsed = 0
      publishAuctionState(false)
    end
  end
  local dt = dtSim
  advanceAuctionTime(dt)
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
      tickApproachingLot(lot, now)
    elseif lot.state == 'exiting' then
      tickExitingLot(lot, now)
    elseif lot.pendingPurchase and now >= (lot.pendingPurchaseUntil or 0) then
      parts.registration.finalizePurchasedLot(lot.lotIndex)
    end
  end

  if auctionState.awaitingFinalExit and not parts.bidding.hasLiveTransitionLots() then
    parts.bidding.setAuctionComplete()
    return
  end

  local lot = parts.bidding.getActiveAuctionLot()
  if not lot then
    return
  end

  if now >= lot.endTime then
    parts.registration.finishCurrentLot()
    return
  end

  parts.bidding.showLiveAuctionStatus(false)
  overhaul_career_market_auctionNpcs.tick(lot, dt, auctionState.npcPersonas)
end

-- Triggers and lifecycle --------------------------------------------------------------------------

local function hideAuctionUiAndDisableAssets()
  parts.presentation.hardDisableAuctionAudioVisuals()
  parts.presentation.closeAuctionOverlayUi()
end

local function onBeamNGTrigger(data)
  if not overhaul_career_career or not overhaul_career_career.isActive() then return end

  local playerVehId = be:getPlayerVehicleID(0)
  if not playerVehId or data.subjectID ~= playerVehId then
    return
  end

  if data.event ~= 'enter' then
    if data.event == 'exit' and auctionState.uiOpen and parts.site.matchesTrigger(data.triggerName, 'counter') then
      parts.flow.cancelCounterPrompt(false)
      guihooks.trigger('UsedAuctionMinimize')
    end
    return
  end

  local isWalking = gameplay_walk.isWalking()

  local facility = parts.site.facilityForEntry(data.triggerName)
  if facility then
    if not isWalking then
      return
    end

    if getAuctionTime() < (auctionState.entryCooldownUntil or 0) then
      return
    end

    if auctionState.phase == 'idle' and not auctionState.entryPaymentPending and not auctionState.transitionActive then
      parts.site.selectFacility(copyTable(facility))
      parts.flow.openEntryPrompt()
    end
    return
  end

  if parts.site.matchesTrigger(data.triggerName, 'counter') then
    if not isWalking then
      return
    end

    parts.flow.openCounterPrompt()
    return
  end

  if parts.site.matchesTrigger(data.triggerName, 'exit') then
    if auctionState.phase ~= 'idle' then
      if parts.view.computeAuctionExitNeedsConfirm() then
        parts.presentation.openMenu()
        guihooks.trigger('UsedAuctionExitRequest')
      else
        parts.session.exitAuctionArea()
      end
    end
  end
end

local function onCareerActivated()
  loadAuctionSettings()
  parts.presentation.setIdleTriggerState()
  hideAuctionUiAndDisableAssets()
  if not tryApplyPendingSavedPreAuctionVehicle() then
    for _, facility in ipairs(parts.site.facilities()) do
      parts.site.selectFacility(facility)
      if parts.session.ejectPlayerFromAuctionInteriorOnCareerLoad() then break end
      parts.site.clearSelection()
    end
  end
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  saveAuctionSettings(currentSavePath, writer)
end

local function onOverhaulSetupInventoryFinished()
  tryApplyPendingSavedPreAuctionVehicle()
end

local function onCareerDeactivatedWhileLevelLoaded()
  parts.session.resetAuction(false)
end

local function onExtensionLoaded()
  hideAuctionUiAndDisableAssets()
end

-- Career modules unload before onOverhaulActive(false). The lot library's state lives as long as this module.
local function onExtensionUnloaded()
  local inventory = overhaul_career_garage_inventory
  if inventory and inventory.cancelPendingAuctionListings then inventory.cancelPendingAuctionListings() end
  require('overhaul/career/market/auction/lots').resetState()
  for _, lot in ipairs(auctionState.lots or {}) do
    if lot.vehId then parts.vehicleControl.cancelLotTransit(lot.vehId) end
    if lot.vehId and not lot.wonInventoryId then
      parts.presentation.deleteVehicleSafe(lot.vehId)
    end
  end
  auctionState.lots = {}
  -- Teardown attempts every cleanup even if a scene object has already been destroyed.
  pcall(parts.site.clearAuctionExitMarker)
  pcall(parts.site.clearAuctionCounterMarker)
  pcall(hideAuctionUiAndDisableAssets)
end

-- Unsold lot vehicles must be gone before a Lua reload serializes stock checkpoints.
require('overhaul/lib/vehicles/temporary').declare('auction', onExtensionUnloaded)

local function onClientStartMission()
  hideAuctionUiAndDisableAssets()
end

local function onWorldReadyState()
  hideAuctionUiAndDisableAssets()
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not overhaul_career_career or not overhaul_career_career.isActive() then return end
  if type(elements) ~= 'table' then
    return
  end

  local level = levelIdentifier or getCurrentLevelIdentifier()
  for _, facility in ipairs(parts.site.facilities(level)) do
    local poi = parts.site.formatAuctionEntrancePoi(level, facility)
    if poi then table.insert(elements, poi) end
  end
end

-- Public API --------------------------------------------------------------------------------------

M.onBeamNGTrigger = onBeamNGTrigger
M.onVehicleSwitched = onVehicleSwitched
M.onUpdate = onUpdate
M.onCareerActivated = onCareerActivated
M.onCareerDeactivatedWhileLevelLoaded = onCareerDeactivatedWhileLevelLoaded
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientStartMission = onClientStartMission
M.onWorldReadyState = onWorldReadyState
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulSetupInventoryFinished = onOverhaulSetupInventoryFinished
M.applyInventorySpawnOverrides = applyInventorySpawnOverrides
M.onUiChangedState = function(toState)
  auctionState.currentUiRoute = toState
  if toState ~= 'used-car-auction' and auctionState.uiOpen then
    auctionState.uiOpen = false
    -- Route departure yields ownership; it must not send a close to the new UI.
    auctionState.counterPromptActive = false
    if auctionState.phase == 'idle' then parts.flow.cancelTravelPrompt() end
    publishAuctionState()
  end
end

M.exitAuctionArea = parts.session.exitAuctionArea
M.listVehicleForNextAnythingGoesAuction = listVehicleForNextAnythingGoesAuction
M.cancelAuctionListing = cancelAuctionListing
M.requestAuctionState = parts.view.requestAuctionState
M.publishAuctionState = publishAuctionState
M.restoreAuctionView = function()
  if auctionState.phase == 'idle' then return false end
  parts.presentation.openMenu()
  publishAuctionState()
  return true
end
-- The Vue view acknowledges a rendered live lot, not just a requested route.
M.onBiddingUiReady = function(lotIndex)
  local lot = parts.bidding.getActiveAuctionLot()
  if auctionState.uiOpen and lot and lot.lotIndex == tonumber(lotIndex) then
    lot.biddingUiReady = true
  end
end
M.startAuction = parts.flow.startAuction
M.cancelTravelPrompt = parts.flow.cancelTravelPrompt
M.openCounterPrompt = parts.flow.openCounterPrompt
M.cancelCounterPrompt = parts.flow.cancelCounterPrompt
M.confirmRegisterNextLot = parts.registration.confirmRegisterNextLot
M.setCounterLotBatchSize = parts.flow.setCounterLotBatchSize
M.placeBid = parts.flow.placeBid
M.passCurrentLot = parts.flow.passCurrentLot
M.setAutoBidEnabled = parts.flow.setAutoBidEnabled
M.setAutoBidMax = parts.flow.setAutoBidMax
M.setAuctionMusicEnabled = parts.flow.setAuctionMusicEnabled
M.finalizePurchasedLot = parts.registration.finalizePurchasedLot
M.afterAiDisabledForFreeze = parts.vehicleControl.afterAiDisabledForFreeze
M.afterAiDisabledForTransit = parts.vehicleControl.afterAiDisabledForTransit
M.closeMenu = parts.flow.closeMenu

return M
