-- Phone Job Broker entry points: state, containers, route and plan previews, and broker actions.
-- Owns the thin phone-side calls into the logistics broker; the broker itself owns the work.
local M = {}
local viewCache = require('overhaul/career/logistics/broker/viewCache')
local snapshots = viewCache.new()
-- Cached UI revisions survive a Lua owner reload; a new owner needs a new namespace.
local revisionSession = Engine.generateUUID()
local revision, sentRevision = 0, nil
local handlingAction = false
local requestId
local screenOpen, pendingRefresh = false, nil
local pollingInputs = viewCache.new()
local dirtyVersion, builtVersion, nextExpiry = 0, -1, math.huge
local currentState

local function cancelRefresh()
  pendingRefresh = nil
  if M.onUpdate then
    M.onUpdate = nil
    extensions.hookUpdate('onUpdate')
  end
end

function M.closeBrokerScreen()
  screenOpen = false
  cancelRefresh()
end

-- The broker is only reachable behind the active-career boundary; freeroam must not load it.
local function careerActive()
  return overhaul_career_career.isActive()
end

local function broker()
  if not careerActive() then return nil end
  return overhaul_career_logistics_broker
end

local function rememberState(jobBroker, data, version, inputs)
  if jobBroker.getPollingState then
    pollingInputs.get('inputs', inputs or jobBroker.getPollingState(), nil, function() return true end)
  end
  nextExpiry = math.huge
  for _, row in ipairs(data.offers or {}) do
    nextExpiry = math.min(nextExpiry, row.offerExpiresAt or math.huge)
  end
  builtVersion = version or dirtyVersion
end

-- Compare immutable snapshots: native rows may be reused and mutated by the
-- next projection. Background publications carry only changed offer fields.
local function offerUpdate(data, previous, yieldWork)
  if not previous then return nil end
  local wire, old = {}, {}
  for key, value in pairs(data) do if key ~= 'offers' then wire[key] = value end end
  for _, row in ipairs(previous.offers or {}) do old[row.id] = row end
  wire.offerPatches, wire.offerOrder = {}, {}
  for _, row in ipairs(data.offers or {}) do
    yieldWork()
    wire.offerOrder[#wire.offerOrder + 1] = row.id
    local before, values, removed = old[row.id], {}, {}
    for key, value in pairs(row) do
      if not before or not viewCache.equal(value, before[key], yieldWork) then values[key] = value end
    end
    for key in pairs(before or {}) do if row[key] == nil then removed[#removed + 1] = key end end
    if next(values) or #removed > 0 then
      wire.offerPatches[#wire.offerPatches + 1] = {id = row.id, values = values, removedFields = removed}
    end
  end
  return wire
end

local function brokerState(data, version, yieldWork, inputs)
  local jobBroker = broker()
  if not jobBroker then return nil end
  data = data or jobBroker.getState()
  data.requestId = requestId
  -- Clock ticks have their own tiny response and must not revise the board.
  local time, baseRevision = data.logisticsTime, currentState and currentState.revision
  data.logisticsTime = nil
  local wire, changed = snapshots.get('state', data, nil, function(previous)
    return yieldWork and offerUpdate(data, previous, yieldWork) or true
  end, yieldWork)
  data.logisticsTime = time
  if changed then revision = revision + 1 end
  data.revision = revisionSession .. ':' .. revision
  rememberState(jobBroker, data, version, inputs)
  currentState = data
  if changed and type(wire) == 'table' then
    wire.baseRevision, wire.revision, wire.logisticsTime = baseRevision, data.revision, time
    return data, wire
  end
  return data
end

-- Requests own the response; action updates own the event. An unchanged backup
-- poll carries no market payload across the bridge.
function M.requestBrokerState(knownRevision)
  screenOpen = true
  cancelRefresh()
  local data = brokerState()
  if not data or data.revision == knownRevision then return nil end
  sentRevision = data.revision
  return data
end

local function publishBrokerState(data, wire)
  data = data or brokerState()
  if not data or data.revision == sentRevision then return end
  sentRevision = data.revision
  guihooks.trigger('phoneBrokerState', wire or data)
end

-- Unchanged polls inspect only position/profile/time. Changed boards are read
-- from existing native offers in slices, without draining generation batches.
function M.requestBrokerUpdates(knownRevision)
  local jobBroker = screenOpen and broker()
  if not jobBroker then return nil end
  -- Recover a missed change event without rebuilding the same board again.
  if currentState and knownRevision and knownRevision ~= currentState.revision then return currentState end
  local inputs, time = jobBroker.getPollingState()
  local _, changed = pollingInputs.get('inputs', inputs, nil, function() return true end)
  if changed then dirtyVersion = dirtyVersion + 1 end
  if dirtyVersion ~= builtVersion or time >= nextExpiry or not knownRevision then
    if not pendingRefresh then
      local version = dirtyVersion
      local timer
      local thread = coroutine.create(function()
        local function yieldWork()
          if timer:stop() >= 2 then coroutine.yield() end
        end
        local data = jobBroker.getState(yieldWork)
        if version ~= dirtyVersion then return end
        return brokerState(data, version, yieldWork, inputs)
      end)
      pendingRefresh = thread
      M.onUpdate = function()
        -- Drop stale work before resuming snapshot comparison/copy. Retry on a
        -- later poll so continuous invalidation cannot spin in this frame.
        if version ~= dirtyVersion then cancelRefresh(); return end
        timer = hptimer()
        local ok, data, wire = coroutine.resume(thread)
        if not ok then
          cancelRefresh()
          log('E', 'phoneBroker', tostring(data))
          return
        end
        if coroutine.status(thread) == 'dead' then
          cancelRefresh()
          if data and version == dirtyVersion then publishBrokerState(data, wire) end
        end
      end
      extensions.hookUpdate('onUpdate')
    end
  end
  return {unchanged = true, logisticsTime = time}
end

local function invalidateBrokerState()
  dirtyVersion = dirtyVersion + 1
end

M.onOverhaulCargoGenerated = invalidateBrokerState
M.onOverhaulLogisticsOffersChanged = invalidateBrokerState
M.onOverhaulEconomyLeavesChanged = invalidateBrokerState
M.onOverhaulPlayerAttributesChanged = invalidateBrokerState
M.onOverhaulUnlockFlagChanged = invalidateBrokerState
M.onOverhaulVehicleAdded = invalidateBrokerState
M.onOverhaulVehicleRemoved = invalidateBrokerState
M.onOverhaulEnterVehicleFinished = invalidateBrokerState
M.onVehicleSwitched = invalidateBrokerState
M.onVehicleSpawned = invalidateBrokerState
M.onVehicleDestroyed = invalidateBrokerState
M.onVehicleResetted = invalidateBrokerState

function M.onOverhaulBrokerPresenceChanged()
  invalidateBrokerState()
  if screenOpen then M.requestBrokerUpdates(sentRevision) end
end

function M.onRouteChanged(change)
  if change.toRoute and change.toRoute.name ~= 'phone-logistics' then M.closeBrokerScreen() end
end

function M.onOverhaulActive(active)
  if not active then M.closeBrokerScreen() end
end
M.onExtensionUnloaded = M.closeBrokerScreen
M.onClientEndMission = M.closeBrokerScreen

-- Native delivery screens finish outside phone actions. Rebuild from the broker
-- after their progress/outcome changes; unchanged views still publish nothing.
local function nativeBrokerStateChanged()
  invalidateBrokerState()
  if not handlingAction and screenOpen then
    cancelRefresh()
    M.requestBrokerUpdates(sentRevision)
  end
end
M.onOverhaulDeliveryFacilityProgressStatsChanged = nativeBrokerStateChanged
M.onOverhaulMaterialContractCompleted = nativeBrokerStateChanged
M.onOverhaulMaterialContractAbandoned = nativeBrokerStateChanged

function M.requestBrokerContainers()
  local jobBroker = broker()
  if not jobBroker then return end
  jobBroker.requestContainers(function(data) guihooks.trigger('phoneBrokerContainers', data) end)
end

function M.requestRoutePreview(id)
  local jobBroker = broker()
  if not jobBroker then return nil end
  return jobBroker.routePreview(id)
end

function M.requestPlanPreview()
  local jobBroker = broker()
  if not jobBroker then return nil end
  return jobBroker.planPreview()
end

-- Each action calls one broker method. Collections also get `done`, which reports their outcome.
function M.requestDiscardGroups(ids)
  local jobBroker = broker()
  return jobBroker and jobBroker.requestDiscardGroups(ids) or {ok = false, message = "Career is not active."}
end

local BROKER_ACTIONS = {
  startHere = function(jobBroker, payload, done) return jobBroker.startHere(payload.id, payload.amount, payload.container, payload.cars, done) end,
  reserve = function(jobBroker, payload) return jobBroker.reserve(payload.id, payload.signature) end,
  reserveMany = function(jobBroker, payload) return jobBroker.reserveMany(payload.items) end,
  cancel = function(jobBroker, payload) return jobBroker.cancel(payload.id) end,
  abandon = function(jobBroker, payload) return jobBroker.abandon(payload.id) end,
  abandonMany = function(jobBroker, payload) return jobBroker.abandonMany(payload.ids) end,
  discardSelectedCargo = function(jobBroker, payload) return jobBroker.discardSelectedCargo(payload.token, payload.selections) end,
  cancelMany = function(jobBroker, payload) return jobBroker.cancelMany(payload.ids) end,
  plan = function(jobBroker, payload) return jobBroker.plan(payload.id) end,
  navigate = function(jobBroker, payload) return jobBroker.navigate(payload.id, payload.leg, payload.stopId) end,
  moveStop = function(jobBroker, payload) return jobBroker.moveStop(payload.index, payload.delta) end,
  showRoute = function(jobBroker) return jobBroker.showRoute() end,
  clearRoute = function(jobBroker) return jobBroker.clearRoute() end,
  optimizeStops = function(jobBroker) return jobBroker.optimizeStops() end,
  pickup = function(jobBroker, payload, done) return jobBroker.pickup(payload.id, payload.amount, payload.container, payload.cars, done) end,
  pickupBatch = function(jobBroker, payload, done) return jobBroker.pickupBatch(payload.items, done) end,
  loadHere = function(jobBroker, payload, done) return jobBroker.loadHere(payload.items, done) end,
  reserveRental = function(jobBroker, payload) return jobBroker.reserveRental(payload.id) end,
  cancelRental = function(jobBroker, payload) return jobBroker.cancelRental(payload.id) end,
  collectRental = function(jobBroker, payload, done) return jobBroker.collectRental(payload.id, done) end,
  returnRental = function(jobBroker, payload, done) return jobBroker.returnRental(payload.id, done) end,
  navigateDepot = function(jobBroker) return jobBroker.navigateDepot() end,
  navigateRental = function(jobBroker, payload) return jobBroker.navigateRental(payload.id) end,
}

function M.brokerAction(action, payload)
  payload = payload or {}
  local jobBroker = broker()
  if not jobBroker then
    return { ok = false, message = 'Career is not active.', requestId = payload.requestId, busy = false }
  end
  cancelRefresh()
  if action ~= 'preferences' then requestId = payload.requestId end

  -- A synchronous collection callback owns its result; a later action return must not publish it again.
  local outcome
  local completed = false
  local function result(ok, message, id)
    local data = brokerState()
    local value = { ok = ok == true, message = message, id = id, requestId = payload.requestId,
      busy = data ~= nil and data.busy == true }
    guihooks.trigger('phoneBrokerResult', value)
    publishBrokerState(data)
    return value
  end
  local function done(ok, message)
    if completed then return end
    completed = true
    outcome = result(ok, message)
  end

  if action == 'preferences' then
    jobBroker.setPreferences(payload.value)
    return { ok = true }
  end
  local handler = BROKER_ACTIONS[action]
  if not handler then return result(false, 'Unknown Job Broker action.') end

  -- Native abandon hooks can fire halfway through cancellation. The action or
  -- its collection callback publishes the final state after the owner finishes.
  handlingAction = true
  local called, ok, message, id = pcall(handler, jobBroker, payload, done)
  handlingAction = false
  if not called then
    done(false, 'The action could not finish. Check your loads before trying again.')
    error(ok, 0)
  end
  if outcome then return outcome end
  return result(ok, message, id)
end

-- Loaded on demand by the phone. Restoring it on Lua reload would load the broker before career is active.
M.onInit = function() extensions.disableSerialization("overhaul_phone_apps_logistics") end

return M
