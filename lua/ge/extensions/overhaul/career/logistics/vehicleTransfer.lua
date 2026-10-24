-- Owns lot-to-lot vehicle transfers, dispatch tickets, saved work and the transfer HUD state. Native offer and task owners perform deliveries; vehicleTransfer/activity.lua exposes the activity.
-- Read config/state, ticket and HUD helpers, dispatch/settlement, save binding, updates/hooks, then shift/status APIs.

local M = {}
local saveStore = require("overhaul/lib/save/store")
local sponsors = require("overhaul/lib/ledger/sponsors")

-- Config ------------------------------------------------------------------------------------------
local SAVE_DIR = "/career/rls_career"
local SAVE_FILE = "/vehicleTransfer.json"
local TASK_GUIDANCE_INTERVAL = 0.25
-- Brand-free Lua IDs; UI brand (CarGo) lives in Vue / phone manifests only.
saveStore.registerKeys({
  {
    key = "logistics.cargoTransfer",
    owner = "overhaul_career_logistics_vehicleTransfer",
    files = { "career/rls_career/vehicleTransfer.json" },
    root = "slot",
    phase = "profile",
    required = true,
    writer = { pretty = true },
  },
})

M.config = {}
local TASK = {
  main = "vehicle-transfer-main",
}

-- State -------------------------------------------------------------------------------------------
local disposeSponsorPayer
local savedFeature
local taskGuidanceTimer = 0
local state = {
  onShift = false,
  phase = "idle", -- idle | betweenRuns | activeTicket
  activeTicket = nil,
  completedTickets = 0,
  sessionMoney = 0,
  lastDropFacId = nil,
  lastError = nil,
  recentOfferIds = {},
  endAfterCurrent = false,
}

local lastTaskSignature = nil

-- Sponsor payer -----------------------------------------------------------------------------------
M.sponsorPayer = {
  order = 10,
  isActive = function() return M.isOnShift() end,
  name = function() return "CarGo" end,
}

local function unregisterSponsorPayer()
  local dispose = disposeSponsorPayer
  disposeSponsorPayer = nil
  if dispose then dispose() end
end

local function registerSponsorPayer()
  unregisterSponsorPayer()
  disposeSponsorPayer = sponsors.registerPayer(M, M.sponsorPayer)
end

-- Shared helpers ----------------------------------------------------------------------------------
local function roundMoney(n) return math.floor((tonumber(n) or 0) + 0.5) end
local function nowSim()
  local general = overhaul_career_logistics_general
  if general then return general.time() end
  return os.time()
end

local function pushState() guihooks.trigger("updateVehicleTransferState", M.getUiState()) end
local function offerOrigin(offer) return offer and (offer.origin or (offer.locations and offer.locations[1])) or nil end

local function offerDestination(offer)
  return offer and (offer.destination or (offer.locations and offer.locations[2])) or nil
end

local function offerFacId(loc) return loc and loc.facId or nil end

local function offerLookupType(offer)
  return (offer and offer.task and offer.task.lookupType) or (offer and offer.data and offer.data.lookupType) or ""
end

local function distanceBetweenLocs(locA, locB)
  local gen = overhaul_career_logistics_generator
  if not (gen and locA and locB) then return math.huge end
  local dist = tonumber((gen.getDistanceBetweenFacilities(locA, locB)))
  if dist and dist > 0 then return dist end
  return math.huge
end

local function distanceBetweenFacIds(facA, facB)
  if not facA or not facB then return math.huge end
  if facA == facB then return 0 end
  return distanceBetweenLocs(
    { type = "facilityParkingspot", facId = facA },
    { type = "facilityParkingspot", facId = facB }
  )
end

local function playerPos()
  local veh = be:getPlayerVehicle(0)
  return veh and veh.getPosition and veh:getPosition() or nil
end

local function originWorldPos(offer)
  local origin = offerOrigin(offer)
  if not origin then return nil end
  local gen = overhaul_career_logistics_generator
  if gen and origin.psPath then
    local spot = gen.getParkingSpotByPath(origin.psPath)
    if spot and spot.pos then return spot.pos end
  end
  if gen then
    local pos = gen.getLocationCoordinates(origin)
    if pos then return pos end
  end
  return nil
end

local function ticketFromOffer(offer)
  local origin = offerOrigin(offer)
  local dest = offerDestination(offer)
  return {
    offerId = offer.id,
    _offer = offer,
    name = offer.name or "Vehicle transfer",
    originFacId = offerFacId(origin),
    destFacId = offerFacId(dest),
    originPsPath = origin and origin.psPath,
    destPsPath = dest and dest.psPath,
    residential = M.isResidentialOffer(offer) and true or false,
    rewardMoney = offer.rewards and tonumber(offer.rewards.money) or 0,
  }
end

local function rememberCompletedOffer(offerId)
  if not offerId then return end
  state.recentOfferIds = state.recentOfferIds or {}
  table.insert(state.recentOfferIds, offerId)
  while #state.recentOfferIds > 3 do
    table.remove(state.recentOfferIds, 1)
  end
end

local function recentExcludeSet()
  local used = {}
  for _, id in ipairs(state.recentOfferIds or {}) do
    used[id] = true
  end
  return used
end

local function offerDistance(offer, fromPos, fromFacId)
  local dist = M.airDistanceToOrigin(offer, fromPos)
  if dist and dist ~= math.huge and dist == dist then return dist end
  if fromFacId then
    dist = distanceBetweenFacIds(fromFacId, offerFacId(offerOrigin(offer)))
    if dist and dist ~= math.huge and dist == dist then return dist end
  end
  return math.huge
end

local function clearActiveTicket() state.activeTicket = nil end
local function markCarGoOfferForSpawn(mgr, ticket)
  local offer = mgr and mgr.getOfferById(ticket.offerId) or ticket._offer
  if not offer then return nil end
  local marker = { offer = offer, previous = offer.carGoTransfer, previousSourceAppId = offer.sourceAppId }
  offer.carGoTransfer = true
  offer.sourceAppId = "vehicle-transfer"
  return marker
end

local function restoreCarGoOfferMarker(ticket)
  local marker = ticket and ticket._carGoMarker
  if marker and marker.offer then
    marker.offer.carGoTransfer = marker.previous
    marker.offer.sourceAppId = marker.previousSourceAppId
  end
  if ticket then ticket._carGoMarker = nil end
end

local function taskDataForOffer(offerId)
  local tasks = overhaul_career_logistics_vehicleTasks
  if not (offerId and tasks) then return nil end
  for _, taskData in ipairs(tasks.getVehicleTasks() or {}) do
    if taskData.offer and taskData.offer.id == offerId and not taskData.remove then return taskData end
  end
  return nil
end

local function observeTicketVehicle(ticket, captureSpawn)
  local task = ticket and taskDataForOffer(ticket.offerId)
  local vehicle = task and be:getObjectByID(task.vehId)
  if not vehicle then return false end
  local pos = vehicle:getPosition()
  local tracked = map.objects and map.objects[task.vehId]
  local damage = tracked and tonumber(tracked.damage)
  if captureSpawn then
    ticket.spawnPosition = { x = pos.x, y = pos.y, z = pos.z }
    ticket.spawnDamage = damage or 0
    ticket.spawnVehicleId = task.vehId
  end
  local origin = ticket.spawnPosition
  if not origin or ticket.spawnVehicleId ~= task.vehId then return false end
  -- Ignore suspension settling; once driven away, returning cannot reset eligibility.
  if (pos.x - origin.x) ^ 2 + (pos.y - origin.y) ^ 2 > 1 then ticket.hasMoved = true end
  if damage and damage > (ticket.spawnDamage or 0) then ticket.hasDamage = true end
  return not ticket.hasMoved and not ticket.hasDamage and damage ~= nil
end

local function hasUnfinishedVehicleWork()
  local tasks = overhaul_career_logistics_vehicleTasks
  if not tasks then return false end
  for _, taskData in ipairs(tasks.getVehicleTasks() or {}) do
    if taskData and not taskData.remove and not taskData.finished and not taskData.processFinishedComplete then
      return true
    end
  end
  return false
end

local function canStageNextTransfer()
  if not state.onShift then return false end
  if state.activeTicket then return false end
  local pendingVehicleId = state._pendingRemovalVehicleId
  if pendingVehicleId then
    if be:getObjectByID(pendingVehicleId) then return false end
    state._pendingRemovalVehicleId = nil
  end
  if hasUnfinishedVehicleWork() then return false end
  return true
end

local function facilityLabel(facId)
  if not facId or facId == "" then return nil end
  local gen = overhaul_career_logistics_generator
  local fac = gen and gen.getFacilityById(facId)
  if fac and type(fac.name) == "string" and fac.name ~= "" then return fac.name end
  return tostring(facId)
end

local function ensureHudVisible() ui_appContainers.showApp("topLeft", "tasks") end
local function playerVehicleId()
  return tonumber(be:getPlayerVehicleID(0)) or 0
end

-- Task guidance -----------------------------------------------------------------------------------
local function clearTaskGuidance()
  guihooks.trigger("DiscardTasklistItem", TASK.main)
  guihooks.trigger("SetTasklistHeader", nil)
  lastTaskSignature = nil
end
-- The label and subtext for one step of an active transfer, from the vehicle task step the player is on.
local function transferStepWording(ticket, vehInfo)
  local origin = facilityLabel(ticket.originFacId) or "pickup"
  local dest = facilityLabel(ticket.destFacId) or "drop-off"
  if
    vehInfo
    and (
      (vehInfo.stepType == "enterVehicle" and not vehInfo.inCargoVehicle)
      or (vehInfo.stepType == "bringToDestination" and not vehInfo.inCargoVehicle and not vehInfo.haulAcquired)
    )
  then
    return "Enter the transfer vehicle", "Pickup: " .. origin
  end
  if
    vehInfo
    and (
      vehInfo.stepType == "confirmDropOff"
      or (vehInfo.stepType == "bringToDestination" and (vehInfo.inCargoVehicle or vehInfo.haulAcquired))
    )
  then
    return "Drop off the vehicle", "Deliver to " .. dest
  end
  if vehInfo and vehInfo.inCargoVehicle then return "Deliver the vehicle", "Drop-off: " .. dest end
  return "Pick up the transfer vehicle", origin .. " → " .. dest
end

-- The HUD label and subtext for the current transfer step, or for waiting between runs.
local function transferTaskWording(ticket, vehInfo, done)
  if state.phase == "betweenRuns" or not ticket then
    local subtext = done > 0 and string.format("%d done today — tap End day in CarGo when finished", done)
      or "Staging the nearest available vehicle"
    return "Looking for next transfer", subtext
  end
  local label, subtext = transferStepWording(ticket, vehInfo)
  if done > 0 then label = string.format("%d · %s", done + 1, label) end
  if state.endAfterCurrent then subtext = subtext .. " — final transfer today" end
  return label, subtext
end

local function refreshTaskGuidance(force)
  if not state.onShift then
    clearTaskGuidance()
    return
  end

  local header = "CarGo"
  local ticket = state.activeTicket
  local done = state.completedTickets or 0
  local vehInfo = overhaul_career_logistics_vehicleTasks
    and overhaul_career_logistics_vehicleTasks.getPrimaryActiveVehicleTaskInfo()
  local label, subtext = transferTaskWording(ticket, vehInfo, done)

  local signature = table.concat({
    header,
    label,
    subtext or "",
    tostring(state.phase),
    tostring(playerVehicleId()),
    vehInfo and vehInfo.inCargoVehicle and "1" or "0",
    vehInfo and tostring(vehInfo.stepType or "") or "",
  }, "|")
  if force or signature ~= lastTaskSignature then
    ensureHudVisible()
    guihooks.trigger("SetTasklistHeader", { label = header })
    guihooks.trigger("SetTasklistTask", {
      id = TASK.main,
      label = label,
      subtext = subtext,
      active = true,
      type = "message",
      clear = false,
    })
    lastTaskSignature = signature
  end
end

local function scheduleHudRepublish()
  if not state.onShift then return end
  lastTaskSignature = nil
  local function run()
    if not state.onShift then return end
    lastTaskSignature = nil
    refreshTaskGuidance(true)
  end
  core_jobsystem.create(function(job)
    job.sleep(0)
    run()
  end)
end

-- Offers and ranking ------------------------------------------------------------------------------
function M.isResidentialOffer(offer)
  local lookup = tostring(offerLookupType(offer))
  if lookup:find("Residential", 1, true) or lookup:find("Private", 1, true) or lookup:find("private", 1, true) then
    return true
  end
  local destId = tostring(offerFacId(offerDestination(offer)) or "")
  if destId:find("[Rr]esidence") or destId:find("[Hh]ome") or destId:find("[Hh]ouse") then return true end
  local gen = overhaul_career_logistics_generator
  local fac = gen and gen.getFacilityById(destId) or nil
  if fac and fac.residential == true then return true end
  return false
end

function M.isTransferVehicleOffer(offer)
  if not offer or not offer.id then return false end
  if offer.spawned then return false end
  if not (offer.data and offer.data.type == "vehicle") then return false end
  if offer.offerExpiresAt and offer.offerExpiresAt <= nowSim() then return false end
  if not offerOrigin(offer) or not offerDestination(offer) then return false end
  if offerFacId(offerOrigin(offer)) == offerFacId(offerDestination(offer)) then return false end
  return true
end

function M.airDistanceToOrigin(offer, fromPos)
  if not fromPos then return math.huge end
  local pos = originWorldPos(offer)
  if pos and fromPos.distance then return fromPos:distance(pos) end
  return math.huge
end

function M.collectTransferOffers(excludeOfferIds)
  if not overhaul_career_career or not overhaul_career_career.isActive() then return {} end
  excludeOfferIds = excludeOfferIds or {}
  local mgr = overhaul_career_logistics_vehicleOfferManager
  local out = {}
  for _, offer in ipairs(mgr.getAllOfferUnexpired() or {}) do
    if M.isTransferVehicleOffer(offer) and not excludeOfferIds[offer.id] then
      local unlockTag = offer.vehicle and offer.vehicle.unlockTag
      local unlocked = (not unlockTag) or mgr.isVehicleTagUnlocked(unlockTag)
      if unlocked then table.insert(out, offer) end
    end
  end
  return out
end
-- Literal nearest unlocked vehicle offer (any distance). Spawn-readiness is checked at spawn time.
function M.rankTransferOffers(opts)
  opts = type(opts) == "table" and opts or {}
  local exclude = opts.excludeOfferIds or {}
  local offers = opts.offers or M.collectTransferOffers(exclude)
  local fromPos = playerPos()
  local fromFacId = opts.fromFacId or state.lastDropFacId
  local ranked = {}
  for _, offer in ipairs(offers) do
    if offer and offer.id and not exclude[offer.id] then
      table.insert(ranked, {
        offer = offer,
        dist = offerDistance(offer, fromPos, fromFacId),
      })
    end
  end
  table.sort(ranked, function(a, b)
    if a.dist ~= b.dist then return a.dist < b.dist end
    return tostring(a.offer.id) < tostring(b.offer.id)
  end)
  return ranked
end

function M.pickNearestOffer(opts)
  opts = type(opts) == "table" and opts or {}
  local ranked = M.rankTransferOffers(opts)
  if not ranked[1] and opts.excludeOfferIds then
    ranked = M.rankTransferOffers({
      fromFacId = opts.fromFacId,
      excludeOfferIds = {},
    })
  end
  return ranked[1] and ticketFromOffer(ranked[1].offer) or nil
end

function M.canCancelUnmovedOffer(offerId)
  local ticket = state.onShift and state.activeTicket
  return ticket and ticket.offerId == offerId and observeTicketVehicle(ticket, false) or false
end

-- Starting and queuing transfers ------------------------------------------------------------------
-- Marks the ticket as the active transfer before the offer manager spawns its vehicle.
local function beginTicketSpawn(ticket, mgr)
  -- Marked before spawning so the immediate-dismiss result survives ticket and offer copies.
  ticket._carGoMarker = markCarGoOfferForSpawn(mgr, ticket)
  state._restoredShift = nil
  state.activeTicket = ticket
  state.phase = "activeTicket"
  state.lastError = nil
  state._autoNextQueued = false
  refreshTaskGuidance(true)
  pushState()
end

-- The first ranked offer this spawn has not tried yet, or nil once the attempts run out.
local function nextUntriedOffer(ranked, attemptExclude, attempts)
  for _, entry in ipairs(ranked) do
    local offer = entry.offer
    if attempts < 6 and offer and offer.id and not attemptExclude[offer.id] then return offer end
  end
  return nil
end

-- Leaves the shift waiting when no offer can be spawned, and tells the player why.
local function reportNoDeliveries(cb)
  clearActiveTicket()
  state.phase = "betweenRuns"
  state.lastError = "No more deliveries available. Please check back later for more assignments"
  refreshTaskGuidance(true)
  pushState()
  ui_message(state.lastError, 7, "warning")
  if cb then cb(false, state.lastError) end
end

local function spawnTicket(ticket, cb, attemptExclude, ranked, rescanned, attempts)
  attempts = (attempts or 0) + 1
  attemptExclude = attemptExclude or {}
  ranked = ranked or {}
  local mgr = overhaul_career_logistics_vehicleOfferManager
  if not (ticket and ticket.offerId and mgr) then
    if cb then cb(false, "spawn unavailable") end
    return false
  end
  beginTicketSpawn(ticket, mgr)
  mgr.spawnOffer(ticket.offerId, false, function(success, reason)
    if not state.onShift then
      restoreCarGoOfferMarker(ticket)
      if cb then cb(false, "Not on shift") end
      return
    end
    if success == true then
      if state.activeTicket ~= ticket then state.activeTicket = ticket end
      state.phase = "activeTicket"
      observeTicketVehicle(ticket, true)
      if state.endAfterCurrent then
        M.endDay()
        if cb then cb(true) end
        return
      end
      refreshTaskGuidance(true)
      pushState()
      ui_message("Transfer assigned — pick up the vehicle.", 6, "info")
      if cb then cb(true) end
      return
    end

    if state.endAfterCurrent then
      restoreCarGoOfferMarker(ticket)
      clearActiveTicket()
      M.endDay()
      if cb then cb(false, reason) end
      return
    end
    restoreCarGoOfferMarker(ticket)
    attemptExclude[ticket.offerId] = true
    local nextOffer = nextUntriedOffer(ranked, attemptExclude, attempts)
    if nextOffer then
      spawnTicket(ticketFromOffer(nextOffer), cb, attemptExclude, ranked, rescanned, attempts)
      return
    end
    if not rescanned and attempts < 6 then
      local refreshed = M.rankTransferOffers({ fromFacId = state.lastDropFacId, excludeOfferIds = attemptExclude })
      if refreshed[1] then
        spawnTicket(ticketFromOffer(refreshed[1].offer), cb, attemptExclude, refreshed, true, attempts)
        return
      end
    end
    reportNoDeliveries(cb)
  end)
  return true
end

local function beginNearestSpawn(cb, opts)
  opts = type(opts) == "table" and opts or {}
  local exclude = opts.excludeOfferIds or recentExcludeSet()
  local ranked = M.rankTransferOffers({
    fromFacId = opts.fromFacId or state.lastDropFacId,
    excludeOfferIds = exclude,
  })
  if not ranked[1] then
    ranked = M.rankTransferOffers({
      fromFacId = opts.fromFacId or state.lastDropFacId,
      excludeOfferIds = {},
    })
  end
  if not ranked[1] then
    reportNoDeliveries(cb)
    return false, state.lastError
  end
  return spawnTicket(ticketFromOffer(ranked[1].offer), cb, {}, ranked)
end

local function queueAutoNext(opts, previousVehicleId)
  if not canStageNextTransfer() then return end
  if state._autoNextQueued then return end
  local token = {}
  state._autoNextQueued = token
  state.phase = "betweenRuns"
  state._pendingRemovalVehicleId = previousVehicleId or state._pendingRemovalVehicleId
  refreshTaskGuidance(true)
  pushState()
  local spawnOpts = opts or { fromFacId = state.lastDropFacId }
  local function previousVehicleStillPresent()
    return previousVehicleId and be:getObjectByID(previousVehicleId) ~= nil
  end
  local function run()
    if state._autoNextQueued ~= token then return end
    state._autoNextQueued = false
    if previousVehicleStillPresent() then
      state.lastError = "The previous transfer vehicle is still being removed. Please try again shortly."
      refreshTaskGuidance(true)
      pushState()
      ui_message(state.lastError, 7, "warning")
      return
    end
    if not canStageNextTransfer() then return end
    beginNearestSpawn(nil, spawnOpts)
  end
  core_jobsystem.create(function(job)
    local waited = 0
    while previousVehicleId and be:getObjectByID(previousVehicleId) and waited < 5 do
      if state._autoNextQueued ~= token or not state.onShift then return end
      job.sleep(0.1)
      waited = waited + 0.1
    end
    job.sleep(1)
    run()
  end)
end

-- Completion --------------------------------------------------------------------------------------
local function onTicketCompleted(ticket, taskData)
  if not state.onShift then return end
  if not ticket then return end
  if ticket._completionHandled then return end
  ticket._completionHandled = true
  state.completedTickets = (state.completedTickets or 0) + 1
  local rewards = taskData and taskData.adjustedRewards
  state.sessionMoney = roundMoney((state.sessionMoney or 0) + (rewards and rewards.money or ticket.rewardMoney or 0))
  state.lastDropFacId = ticket.destFacId
  rememberCompletedOffer(ticket.offerId)
  restoreCarGoOfferMarker(ticket)
  clearActiveTicket()
  state.phase = "betweenRuns"
  if state.endAfterCurrent then
    M.endDay()
    return
  end
  refreshTaskGuidance(true)
  ui_message("Transfer complete. Staging the next nearest vehicle.", 5, "success")
  pushState()
  queueAutoNext({ fromFacId = state.lastDropFacId }, taskData and taskData.vehId)
end

function M.onVehicleTaskRemoved(taskData)
  if not state.onShift then return end
  local ticket = state.activeTicket
  if not (ticket and taskData and taskData.offer and taskData.offer.id == ticket.offerId) then return end
  ticket._seenTask = true
  if taskData.finished or taskData.processFinishedComplete then
    onTicketCompleted(ticket, taskData)
    return
  end
  restoreCarGoOfferMarker(ticket)
  clearActiveTicket()
  state.phase = "betweenRuns"
  if state.endAfterCurrent then
    M.endDay()
    return
  end
  state.lastError = nil
  refreshTaskGuidance(true)
  pushState()
  if taskData.giveBack then
    if taskData.undeliverable then
      ui_message("Vehicle reported undeliverable. Staging the next nearest vehicle.", 6, "info")
    end
    queueAutoNext({ fromFacId = state.lastDropFacId or ticket.originFacId or ticket.destFacId }, taskData.vehId)
  end
end

local function saveFeature()
  if not savedFeature then
    savedFeature = assert(saveStore.bind(overhaul_career_saveSystem).feature("logistics.cargoTransfer", {
      owner = "overhaul_career_logistics_vehicleTransfer",
      files = { SAVE_DIR:sub(2) .. SAVE_FILE },
      root = "slot",
      phase = "profile",
      required = true,
      writer = { pretty = true },
      capture = function(context, writer)
        writer = writer or context.writer
        local dirPath = context.base .. SAVE_DIR
        local filePath = context.path()
        if not state.onShift then
          -- Reused slots must not retain an older shift's file.
          if FS:fileExists(filePath) then writer.remove(filePath) end
          return
        end
        if not writer.exists(dirPath) then writer.mkdir(dirPath) end
        context.write({
          onShift = true,
          completedTickets = state.completedTickets or 0,
          sessionMoney = roundMoney(state.sessionMoney),
          lastDropFacId = state.lastDropFacId,
          endAfterCurrent = state.endAfterCurrent and true or false,
        })
      end,
    }))
  end
  return savedFeature
end

-- Per-frame update --------------------------------------------------------------------------------
function M.onUpdate(dtReal, dtSim, dtRaw)
  if not state.onShift then return end
  taskGuidanceTimer = taskGuidanceTimer + (tonumber(dtReal) or 0)
  if taskGuidanceTimer >= TASK_GUIDANCE_INTERVAL then
    taskGuidanceTimer = 0
    refreshTaskGuidance(false)
  end

  local ticket = state.activeTicket
  if ticket and ticket.offerId then
    local taskData = taskDataForOffer(ticket.offerId)
    if taskData then
      observeTicketVehicle(ticket, false)
      ticket._seenTask = true
      if taskData.finished or taskData.processFinishedComplete then onTicketCompleted(ticket, taskData) end
      return
    end
  end

  -- A shift loaded from a save picks up its transfer once the delivery save restores the task.
  if not ticket and state._restoredShift then
    local tasks = overhaul_career_logistics_vehicleTasks
    for _, taskData in ipairs(tasks and tasks.getVehicleTasks() or {}) do
      if
        taskData.offer
        and taskData.offer.carGoTransfer
        and not taskData.remove
        and not taskData.finished
        and not taskData.processFinishedComplete
      then
        ticket = ticketFromOffer(taskData.offer)
        ticket._carGoMarker = { offer = taskData.offer }
        ticket._seenTask = true
        state._restoredShift = nil
        state.activeTicket = ticket
        state.phase = "activeTicket"
        refreshTaskGuidance(true)
        pushState()
        return
      end
    end
  end
end

-- Save and lifecycle ------------------------------------------------------------------------------
function M.onCareerActivated()
  registerSponsorPayer()
  state.endAfterCurrent = false
  state.onShift = false
  state.phase = "idle"
  restoreCarGoOfferMarker(state.activeTicket)
  clearActiveTicket()
  state.completedTickets = 0
  state.sessionMoney = 0
  state.lastDropFacId = nil
  state.lastError = nil
  state.recentOfferIds = {}
  clearActiveTicket()
  state._autoNextQueued = false
  state._pendingRemovalVehicleId = nil
  state._restoredShift = nil
  clearTaskGuidance()
  pushState()
end

function M.onOverhaulSaveCurrentProfile(currentSavePath, _, writer) saveFeature().capture(currentSavePath, writer) end
-- Every profile load starts from its own save; the open transfer task comes back through the delivery save.
function M.onOverhaulActive(active)
  M.onCareerActivated()
  if not active then
    unregisterSponsorPayer()
    return
  end
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  local data = savePath and jsonReadFile(saveFeature().path(savePath))
  if type(data) ~= "table" or data.onShift ~= true then return end
  state.onShift = true
  state.phase = "betweenRuns"
  state.completedTickets = math.max(0, math.floor(tonumber(data.completedTickets) or 0))
  state.sessionMoney = roundMoney(data.sessionMoney)
  state.lastDropFacId = data.lastDropFacId
  state.endAfterCurrent = data.endAfterCurrent == true
  state._restoredShift = true
  refreshTaskGuidance(true)
  pushState()
end

M.onClientStartMission = registerSponsorPayer
M.onClientEndMission = unregisterSponsorPayer
M.onExtensionUnloaded = function()
  unregisterSponsorPayer()
  if savedFeature then
    savedFeature.dispose()
    savedFeature = nil
  end
end

-- Public API: shift and status --------------------------------------------------------------------
function M.ownsHudTasklist() return state.onShift and true or false end

function M.refreshHudTasklist(force) refreshTaskGuidance(force and true or false) end
function M.refreshHudTasklistAfterUi() scheduleHudRepublish() end
function M.getUiState()
  local ticket = state.activeTicket
  local canNext = state.onShift and state.phase == "betweenRuns" and not state.activeTicket
  local activeTask = ticket and taskDataForOffer(ticket.offerId)
  return {
    onShift = state.onShift and true or false,
    phase = state.phase,
    completedTickets = state.completedTickets or 0,
    sessionMoney = roundMoney(state.sessionMoney or 0),
    canNextRun = canNext and true or false,
    canReportUndeliverable = activeTask and not activeTask.remove and not activeTask.finished or false,
    endAfterCurrent = state.endAfterCurrent and true or false,
    lastError = state.lastError,
    ticket = ticket and {
      offerId = ticket.offerId,
      name = ticket.name,
      originFacId = ticket.originFacId,
      destFacId = ticket.destFacId,
      originLabel = facilityLabel(ticket.originFacId),
      destLabel = facilityLabel(ticket.destFacId),
      residential = ticket.residential and true or false,
      rewardMoney = ticket.rewardMoney or 0,
      active = true,
    } or nil,
    freeTaxi = state.onShift and true or false,
  }
end

function M.requestState()
  pushState()
  return M.getUiState()
end

function M.isOnShift() return state.onShift and true or false end
function M.isActiveTransferVehicle(vehId)
  local ticket = state.onShift and state.activeTicket
  local taskData = ticket and taskDataForOffer(ticket.offerId)
  return taskData and taskData.vehId == vehId and not taskData.remove and not taskData.finished or false
end

function M.reportUndeliverable(vehId)
  if not overhaul_career_career or not overhaul_career_career.isActive() then return false end
  local ticket = state.onShift and state.activeTicket
  local taskData = ticket and taskDataForOffer(ticket.offerId)
  if not taskData or taskData.remove or taskData.finished or (vehId and taskData.vehId ~= vehId) then return false end
  local tasks = overhaul_career_logistics_vehicleTasks
  return tasks and tasks.reportVehicleUndeliverable(taskData.vehId) or false
end

function M.nextRun(opts)
  if not overhaul_career_career.isActive() then return false, "Not on shift" end
  opts = type(opts) == "table" and opts or {}
  if not state.onShift then
    state.lastError = "Not on shift"
    pushState()
    return false, state.lastError
  end
  if state._autoNextQueued then return false, "Preparing the next pickup. Please wait." end
  if
    state._pendingRemovalVehicleId
    and be:getObjectByID(state._pendingRemovalVehicleId)
  then
    return false, "The previous transfer vehicle is still being removed. Please wait."
  end
  if state.activeTicket or hasUnfinishedVehicleWork() then
    state.lastError = "Finish the current transfer first"
    pushState()
    return false, state.lastError
  end
  state.lastError = nil
  state.phase = "activeTicket"
  refreshTaskGuidance(true)
  pushState()
  return beginNearestSpawn(nil, opts)
end

function M.startDay(opts)
  if not overhaul_career_career.isActive() then return false, "Career is not active." end
  opts = type(opts) == "table" and opts or {}
  local emp = overhaul_career_work_employment
  if (emp.hasCompanyShift()) or (emp.isOnShift()) or (emp.isAssignmentPaused()) then
    state.lastError = "End your company shift before starting a CarGo day."
    pushState()
    return false, state.lastError
  end
  if state.onShift then
    state.lastError = "Already on shift"
    pushState()
    return false, state.lastError
  end
  state.onShift = true
  state.phase = "betweenRuns"
  state.completedTickets = 0
  state.sessionMoney = 0
  state.lastDropFacId = opts.startFacId
  state.lastError = nil
  state.recentOfferIds = {}
  state.endAfterCurrent = false
  clearActiveTicket()
  refreshTaskGuidance(true)
  pushState()
  return M.nextRun(opts)
end

function M.endDay()
  if not state.onShift then
    state.lastError = "Not on shift"
    pushState()
    return false, state.lastError
  end
  if state.activeTicket then
    local tasks = overhaul_career_logistics_vehicleTasks
    local offerId = state.activeTicket.offerId
    if not (M.canCancelUnmovedOffer(offerId) and tasks and tasks.cancelUnmovedTransfer(offerId)) then
      state.endAfterCurrent = true
      state.lastError = nil
      refreshTaskGuidance(true)
      pushState()
      ui_message("Finish the current transfer to end your CarGo day. No further vehicle will be assigned.", 7, "info")
      return true, "afterCurrent"
    end
  end
  local completed = state.completedTickets or 0
  restoreCarGoOfferMarker(state.activeTicket)
  clearActiveTicket()
  state.onShift = false
  state.phase = "idle"
  state.lastError = nil
  state._autoNextQueued = false
  state._pendingRemovalVehicleId = nil
  state.endAfterCurrent = false
  clearTaskGuidance()
  local general = overhaul_career_logistics_general
  if general then general.checkExitDeliveryMode() end
  pushState()
  if completed > 0 then
    ui_message(string.format("CarGo day ended (%d transfers).", completed), 6, "info")
  else
    ui_message("CarGo day ended.", 5, "info")
  end
  return true, completed
end

M._distanceBetweenFacIds = distanceBetweenFacIds
M._ticketFromOffer = ticketFromOffer
M._state = function() return state end

-- Activity ----------------------------------------------------------------------------------------
M.activity = require("overhaul/career/logistics/vehicleTransfer/activity")(M)

-- Game hooks --------------------------------------------------------------------------------------
function M.onOverhaulDeliveryModeStopped()
  if not state.onShift then return end
  -- Delivery mode has already charged abandonment; do not charge it twice.
  restoreCarGoOfferMarker(state.activeTicket)
  clearActiveTicket()
  state.onShift = false
  state.phase = "idle"
  state.endAfterCurrent = false
  state._autoNextQueued = false
  state._pendingRemovalVehicleId = nil
  clearTaskGuidance()
  pushState()
end

function M.onExtensionLoaded()
  registerSponsorPayer()
  pushState()
end

function M.onUIPlayStateChanged(enteredPlay)
  if enteredPlay then scheduleHudRepublish() end
end

function M.onOverhaulDeliveryRewardsPopupClosed() scheduleHudRepublish() end
function M.onUiReady(uiType)
  if uiType == "vue" then scheduleHudRepublish() end
end

function M.onDeactivateBigMapCallback() scheduleHudRepublish() end
function M.onVehicleSwitched(oldId, newId, player)
  if not state.onShift then return end
  lastTaskSignature = nil
  refreshTaskGuidance(true)
end

return M
