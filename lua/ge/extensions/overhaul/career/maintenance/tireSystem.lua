-- Tire wear, grip context and fresh-wheel resets for personal and business vehicles.
-- Config, state and shared helpers, context parts, update and lifecycle, wheel APIs and game hooks.

local M = {}
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")

local jbeamIO = require("jbeam/io")
local tireModel = require("common/overhaul/tireModel")
local capabilities = require("overhaul/lib/platform/capabilities")

-- Config ------------------------------------------------------------------------------------------

local metersToMiles = 1 / 1609.344
-- Context ticks run half a second out of phase with the career modules' other 1 s timers.
local CONTEXT_PHASE = 0.5

local FLUSH_AND_RESET_COMMAND = "if overhaulTires then " .. vehicleCommands.call("overhaulTires", "flushState") .. "; "
    .. vehicleCommands.call("overhaulTires", "resetThermalsAndGrip") .. " end"
local FLUSH_COMMAND = "if overhaulTires then " .. vehicleCommands.call("overhaulTires", "flushState") .. " end"

-- State -------------------------------------------------------------------------------------------

-- Shared runtime state for this load, passed to every tire part.
local tireState = {}

local contextTimer = CONTEXT_PHASE
local burnoutOverrides = {}
local dynoOverrides = {}
local dynoSnapshots = {}
local lastContextSignatures = {}
local providerNoticeKey
local ioCtxCache = {}
local partRevisions = {}
local runtimeOwnersByVehId = {}

-- Tire payloads -----------------------------------------------------------------------------------

local commandPayloads = {}

local function serializedCall(functionName, ...)
  local call = vehicleCommands.call("overhaulTires", functionName)
  local arguments = {}
  for index = 1, select('#', ...) do
    local value = select(index, ...)
    arguments[index] = serialize(value)
  end
  return call:sub(1, -2) .. table.concat(arguments, ', ') .. ')'
end

function commandPayloads.configure(context)
  return serializedCall("configure", context)
end

function commandPayloads.ambientTemperature(temperature, initialState)
  local initialArgument = initialState and (", " .. serialize(initialState)) or ""
  local call = vehicleCommands.call("overhaulTires", "setAmbientTemperature")
  return call:sub(1, -2) .. serialize(temperature) .. initialArgument .. ')'
end

function commandPayloads.freshState(initialState)
  if type(initialState) == "table" then return serializedCall("applyFreshAndInflate", initialState) end
  return vehicleCommands.call("overhaulTires", "applyFreshAndInflate")
end

function commandPayloads.disabledInspection()
  local call = vehicleCommands.call("overhaulTires", "configure")
  return call:sub(1, -2)
    .. "{enabled=false,maintenanceEnabled=false,ambientTemperature=21,initialState={},defaultRemaining=1,groundModels={}})"
end

-- Helpers -----------------------------------------------------------------------------------------

local function configureProviderCommand(context)
  return "if not overhaulTires then extensions.load('overhaulTires') end; " ..
    "if overhaulTires and overhaulTires.configure then " ..
    "if rawget(_G,'rlsTireProviderLoadErrorReported') then rawset(_G,'rlsTireProviderLoadErrorReported',nil) end; " ..
    commandPayloads.configure(context) .. " " ..
    "elseif not rawget(_G,'rlsTireProviderLoadErrorReported') then " ..
    "rawset(_G,'rlsTireProviderLoadErrorReported',true); " ..
    "log('E','overhaulTires','Unable to load the RLS tire provider') end"
end

local function round(value, digits)
  local scale = 10 ^ (digits or 0)
  return math.floor((tonumber(value) or 0) * scale + 0.5) / scale
end

local function isMaintenanceEnabled()
  return overhaul_career_maintenance_maintenanceMode.isEnabled() == true
end

local function markDirty(inventoryId)
  overhaul_career_garage_inventory.setVehicleDirty(tonumber(inventoryId))
end

local function vehicleDataForInventory(inventoryId)
  return overhaul_career_garage_inventory.getVehicle(tonumber(inventoryId)) or nil
end

local function businessVehicleData(businessId, vehicleId)
  local inventory = capabilities.get("businessVehicles")
  return inventory and inventory.getVehicleById(businessId, vehicleId) or nil
end

local function markOwnerDirty(owner)
  if owner and owner.kind == "personal" then
    markDirty(owner.inventoryId)
  end
end

local function freshWheelState()
  return {remaining = 1, flat = false}
end

-- A part's tyre state lives on the part itself, and mirrors into its tags so a reconciliation keeps it.
local function partState(part)
  if type(part) ~= "table" then
    return nil
  end
  if type(part.rlsTireState) == "table" then
    return part.rlsTireState
  end
  if type(part.tags) == "table" and type(part.tags.rlsTireState) == "table" then
    return part.tags.rlsTireState
  end
  return nil
end

local function setPartState(part, state)
  if type(part) ~= "table" then
    return
  end
  part.tags = type(part.tags) == "table" and part.tags or {}
  part.rlsTireState = state
  -- The base inventory reconciler preserves tags. Keep a mirror here so tire state survives a spawned-vehicle reconciliation that rebuilds the record.
  part.tags.rlsTireState = state
end

local function milesForPart(part, vehicleData)
  local odometer = part and part.partCondition and tonumber(part.partCondition.odometer)
  if odometer ~= nil then
    return math.max(0, odometer * metersToMiles)
  end
  return math.max(0, tonumber(vehicleData and vehicleData.mileage) or 0) * metersToMiles
end

-- Returns the wheel's stored state, the part's whole state, and whether the wheel state was just created.
local function ensurePartWheelState(part, wheelName, vehicleData, forcedFresh)
  local state = partState(part)
  local created = false
  if type(state) ~= "table" then
    state = {schemaVersion = 1, wheels = {}}
  end
  state.schemaVersion = 1
  state.wheels = type(state.wheels) == "table" and state.wheels or {}
  local wheelState = state.wheels[wheelName]
  if type(wheelState) ~= "table" then
    created = true
    wheelState = {
      remaining = forcedFresh and 1 or tireModel.remainingFromMiles(milesForPart(part, vehicleData)),
      flat = false,
    }
    state.wheels[wheelName] = wheelState
  end
  wheelState.remaining = tireModel.clamp(wheelState.remaining, 0, 1)
  wheelState.flat = wheelState.flat == true
  setPartState(part, state)
  return wheelState, state, created
end

local function personalInventory()
  return overhaul_career_parts_partInventory.getInventory() or {}
end

-- Finds the tyre part fitted at a location: by its part path, then its containing slot, then its origin name.
local function findPersonalPart(inventoryId, partPath, partOrigin, containingSlot)
  inventoryId = tonumber(inventoryId)
  local fallbackId, fallbackPart
  for partId, part in pairs(personalInventory()) do
    if part and tonumber(part.location) == inventoryId then
      if partPath and part.partPath == partPath then
        return partId, part
      end
      if containingSlot and part.containingSlot == containingSlot and (not partOrigin or part.name == partOrigin) then
        return partId, part
      end
      if partOrigin and part.name == partOrigin and not fallbackPart then
        fallbackId, fallbackPart = partId, part
      end
    end
  end
  return fallbackId, fallbackPart
end

-- The parts at one location, in inventory iteration order.
local function personalPartsAt(inventoryId)
  inventoryId = tonumber(inventoryId)
  local parts = {}
  for _, part in pairs(personalInventory()) do
    if part and tonumber(part.location) == inventoryId then
      parts[#parts + 1] = part
    end
  end
  return parts
end

-- Returns the wheel's state under a vehicle-level path, the path's state, and whether either was created.
local function ensureVehicleFallbackState(vehicleData, path, wheelName, remaining)
  vehicleData.rlsTireStateByPartPath = type(vehicleData.rlsTireStateByPartPath) == "table" and
                                         vehicleData.rlsTireStateByPartPath or {}
  local state = vehicleData.rlsTireStateByPartPath[path]
  local created = false
  if type(state) ~= "table" then
    created = true
    state = {schemaVersion = 1, wheels = {}}
    vehicleData.rlsTireStateByPartPath[path] = state
  end
  state.wheels = type(state.wheels) == "table" and state.wheels or {}
  if type(state.wheels[wheelName]) ~= "table" then
    created = true
    state.wheels[wheelName] = {remaining = tireModel.clamp(remaining, 0, 1), flat = false}
  end
  return state.wheels[wheelName], state, created
end

-- A string that changes whenever a wheel's wear, rounded to whole percent, or flat state changes.
local function currentTireSignature(vehicleData)
  local rows = {}
  for _, wheel in ipairs(vehicleData and vehicleData.rlsTireLayout and vehicleData.rlsTireLayout.wheels or {}) do
    table.insert(rows, string.format("%s:%d:%d", tostring(wheel.name),
      math.floor(tireModel.clamp(wheel.remaining, 0, 1) * 100 + 0.5), wheel.flat == true and 1 or 0))
  end
  table.sort(rows)
  return table.concat(rows, "|")
end

-- A tyre inspection stops counting once the tyres change.
local function maybeInvalidateInspection(vehicleData)
  local computerState = vehicleData and vehicleData.maintenanceComputerState
  local inspection = computerState and computerState.tireInspection
  if inspection and inspection.signature ~= currentTireSignature(vehicleData) then
    computerState.tireInspection = nil
    return true
  end
  return false
end

-- Tells the player once per provider that an external tyre provider is driving the tyres.
local function showProviderNotice(provider)
  if type(provider) ~= "table" or provider.source ~= "external" then
    return
  end
  local key = table.concat({tostring(provider.id), tostring(provider.version), tostring(provider.apiVersion)}, ":")
  if providerNoticeKey == key then
    return
  end
  providerNoticeKey = key
  local message
  if provider.integrated == true then
    message = string.format("External tire provider selected: %s %s", provider.name or provider.id or "Tyre Wear and Thermals",
      provider.version or "")
  else
    message = "External Tyre Wear and Thermals selected (legacy API). RLS persistence, maintenance gating, towing protection, and tire replacement are unavailable."
  end
  ui_message(message, 12, "tireProvider", provider.integrated and "info" or "warning")
end

-- Parts -------------------------------------------------------------------------------------------

local parts = {}

local partInputs = {
  context = {
    commandPayloads = commandPayloads,
    state = tireState,
    M = M,
    burnoutOverrides = burnoutOverrides,
    businessVehicleData = businessVehicleData,
    configureProviderCommand = configureProviderCommand,
    currentTireSignature = currentTireSignature,
    deepCopy = deepcopy,
    dynoOverrides = dynoOverrides,
    dynoSnapshots = dynoSnapshots,
    ensurePartWheelState = ensurePartWheelState,
    ensureVehicleFallbackState = ensureVehicleFallbackState,
    findPersonalPart = findPersonalPart,
    freshWheelState = freshWheelState,
    isMaintenanceEnabled = isMaintenanceEnabled,
    lastContextSignatures = lastContextSignatures,
    markDirty = markDirty,
    markOwnerDirty = markOwnerDirty,
    maybeInvalidateInspection = maybeInvalidateInspection,
    metersToMiles = metersToMiles,
    partRevisions = partRevisions,
    partState = partState,
    personalInventory = personalInventory,
    personalPartsAt = personalPartsAt,
    round = round,
    runtimeOwnersByVehId = runtimeOwnersByVehId,
    showProviderNotice = showProviderNotice,
    tireModel = tireModel,
    vehicleDataForInventory = vehicleDataForInventory,
  },
  quotes = {
    M = M,
    businessVehicleData = businessVehicleData,
    currentTireSignature = currentTireSignature,
    deepCopy = deepcopy,
    findPersonalPart = findPersonalPart,
    ioCtxCache = ioCtxCache,
    isMaintenanceEnabled = isMaintenanceEnabled,
    jbeamIO = jbeamIO,
    markDirty = markDirty,
    round = round,
    tireModel = tireModel,
    vehicleDataForInventory = vehicleDataForInventory,
  },
  checkout = {
    parts = parts,
    M = M,
    businessVehicleData = businessVehicleData,
    deepCopy = deepcopy,
    findPersonalPart = findPersonalPart,
    freshWheelState = freshWheelState,
    markDirty = markDirty,
    partRevisions = partRevisions,
    personalInventory = personalInventory,
    round = round,
    setPartState = setPartState,
    tireModel = tireModel,
    vehicleDataForInventory = vehicleDataForInventory,
  },
}

parts.context = require('overhaul/career/maintenance/tireSystem/context').new(partInputs.context)
-- Quotes attach their screen functions to M, so the part needs no handle of its own.
require('overhaul/career/maintenance/tireSystem/quotes').new(partInputs.quotes)
require('overhaul/career/maintenance/tireSystem/checkout').new(partInputs.checkout)


-- Update ------------------------------------------------------------------------------------------

function M.onUpdate(dtReal, dtSim)
  contextTimer = contextTimer + (tonumber(dtSim) or tonumber(dtReal) or 0)
  if contextTimer < 1 then return end
  contextTimer = contextTimer % 1
  parts.context.sendAllContexts(false)
end

-- Lifecycle ---------------------------------------------------------------------------------------

-- Registers every fleet vehicle that is out on the road, then sends fresh contexts for everything.
function M.onOverhaulActive()
  local manager = overhaul_career_business_manager
  local purchased = manager.getAllPurchasedBusinesses() or {}
  for _, businessesById in pairs(purchased) do
    for businessId, owned in pairs(businessesById or {}) do
      if owned == true or type(owned) == "table" then
        local fleet = capabilities.get("businessVehicles")
        for _, vehicleData in ipairs(fleet and fleet.getPulledOutVehicles and fleet.getPulledOutVehicles(businessId) or {}) do
          local vehicleId = vehicleData and vehicleData.vehicleId
          local vehId = vehicleId and capabilities.get("businessVehicles").getSpawnedVehicleId(businessId, vehicleId)
          if vehId then M.registerBusinessVehicle(businessId, vehicleId, vehId) end
        end
      end
    end
  end
  parts.context.sendAllContexts(true)
end

function M.onClientEndMission()
  for inventoryId in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
    local vehObj = vehId and getObjectByID(vehId) or nil
    if vehObj then vehObj:queueLuaCommand(FLUSH_AND_RESET_COMMAND) end
  end
  for vehId in pairs(runtimeOwnersByVehId) do
    local vehObj = getObjectByID(vehId)
    if vehObj then
      vehObj:queueLuaCommand(FLUSH_AND_RESET_COMMAND)
    end
  end
  for inventoryId in pairs(burnoutOverrides) do burnoutOverrides[inventoryId] = nil end
  local activeDynoIds = {}
  for inventoryId in pairs(dynoSnapshots) do table.insert(activeDynoIds, inventoryId) end
  for _, inventoryId in ipairs(activeDynoIds) do
    parts.context.restoreDynoSnapshot(inventoryId)
    dynoSnapshots[inventoryId] = nil
    dynoOverrides[inventoryId] = nil
  end
  for inventoryId in pairs(dynoOverrides) do dynoOverrides[inventoryId] = nil end
end

-- Public API: wheel resets ------------------------------------------------------------------------------------

local function normalizeWheelNameSet(wheelNames)
  local set = {}
  if type(wheelNames) ~= "table" then
    return set
  end
  for key, value in pairs(wheelNames) do
    if type(key) == "number" and type(value) == "string" and value ~= "" then
      set[value] = true
    elseif type(key) == "string" and key ~= "" and value then
      set[key] = true
    end
  end
  return set
end

-- Re-sends a vehicle's context and reinflates its live tyres after a reset.
local function refreshLiveTires(inventoryId)
  partRevisions[inventoryId] = (tonumber(partRevisions[inventoryId]) or 0) + 1
  markDirty(inventoryId)

  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
  if not vehId then
    return
  end
  M.sendContextForVehicle(vehId, true)
  local vehicleData = vehicleDataForInventory(inventoryId)
  parts.context.applyFreshTiresOnVehId(vehId, vehicleData and parts.context.buildInitialWheelState(inventoryId, vehicleData) or nil)
end

-- Freeroam+/cheats Insert recover: clear persisted tire wear/flats and reinflate live tires.
function M.forceFreshForVehicle(inventoryId)
  inventoryId = tonumber(inventoryId)
  local vehicleData = vehicleDataForInventory(inventoryId)
  if not inventoryId or not vehicleData then
    return false
  end

  local inventory = personalInventory()
  for _, part in pairs(inventory) do
    if type(part) == "table" and tonumber(part.location) == inventoryId then
      local state = partState(part)
      if type(state) == "table" and type(state.wheels) == "table" then
        for wheelName in pairs(state.wheels) do
          state.wheels[wheelName] = freshWheelState()
        end
        setPartState(part, state)
      end
    end
  end

  vehicleData.rlsTireStateByPartPath = type(vehicleData.rlsTireStateByPartPath) == "table" and
                                         vehicleData.rlsTireStateByPartPath or {}
  for _, state in pairs(vehicleData.rlsTireStateByPartPath) do
    if type(state) == "table" and type(state.wheels) == "table" then
      for wheelName in pairs(state.wheels) do
        state.wheels[wheelName] = freshWheelState()
      end
    end
  end
  if type(vehicleData.rlsTireLayout) == "table" and type(vehicleData.rlsTireLayout.wheels) == "table" then
    for _, wheel in ipairs(vehicleData.rlsTireLayout.wheels) do
      wheel.remaining = 1
      wheel.flat = false
    end
  end

  refreshLiveTires(inventoryId)
  return true
end

-- Roadside selective repair: refresh only the named wheels.
function M.forceFreshWheels(inventoryId, wheelNames, deferRefresh)
  inventoryId = tonumber(inventoryId)
  local vehicleData = vehicleDataForInventory(inventoryId)
  local wanted = normalizeWheelNameSet(wheelNames)
  if not inventoryId or not vehicleData or not next(wanted) then
    return false
  end

  local touched = false
  local inventory = personalInventory()
  for _, part in pairs(inventory) do
    if type(part) == "table" and tonumber(part.location) == inventoryId then
      local state = partState(part)
      if type(state) == "table" and type(state.wheels) == "table" then
        local partTouched = false
        for wheelName in pairs(state.wheels) do
          if wanted[wheelName] then
            state.wheels[wheelName] = freshWheelState()
            partTouched = true
            touched = true
          end
        end
        if partTouched then
          setPartState(part, state)
        end
      end
    end
  end

  vehicleData.rlsTireStateByPartPath = type(vehicleData.rlsTireStateByPartPath) == "table" and
                                         vehicleData.rlsTireStateByPartPath or {}
  for _, state in pairs(vehicleData.rlsTireStateByPartPath) do
    if type(state) == "table" and type(state.wheels) == "table" then
      for wheelName in pairs(state.wheels) do
        if wanted[wheelName] then
          state.wheels[wheelName] = freshWheelState()
          touched = true
        end
      end
    end
  end
  if type(vehicleData.rlsTireLayout) == "table" and type(vehicleData.rlsTireLayout.wheels) == "table" then
    for _, wheel in ipairs(vehicleData.rlsTireLayout.wheels) do
      if type(wheel) == "table" and wanted[tostring(wheel.name or "tire")] then
        wheel.remaining = 1
        wheel.flat = false
        touched = true
      end
    end
  end

  if not touched then
    return false
  end
  if not deferRefresh then refreshLiveTires(inventoryId) end
  return true
end

M.refreshLiveTires = refreshLiveTires

-- Clears the flats on every wheel of a vehicle and its parts, and reinflates the live tyres.
function M.clearFlatsForVehicle(inventoryId)
  inventoryId = tonumber(inventoryId)
  local vehicleData = vehicleDataForInventory(inventoryId)
  if not inventoryId or not vehicleData then
    return false
  end

  local function clearWheels(state)
    if type(state) ~= "table" or type(state.wheels) ~= "table" then
      return false
    end
    for _, wheelState in pairs(state.wheels) do
      if type(wheelState) == "table" then
        wheelState.flat = false
      end
    end
    return true
  end

  for _, part in pairs(personalInventory()) do
    if type(part) == "table" and tonumber(part.location) == inventoryId then
      local state = partState(part)
      if clearWheels(state) then
        setPartState(part, state)
      end
    end
  end
  for _, state in pairs(type(vehicleData.rlsTireStateByPartPath) == "table" and
                          vehicleData.rlsTireStateByPartPath or {}) do
    clearWheels(state)
  end
  for _, wheel in ipairs(vehicleData.rlsTireLayout and vehicleData.rlsTireLayout.wheels or {}) do
    if type(wheel) == "table" then
      wheel.flat = false
    end
  end

  partRevisions[inventoryId] = (tonumber(partRevisions[inventoryId]) or 0) + 1
  markDirty(inventoryId)

  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
  if vehId then
    M.sendContextForVehicle(vehId, true)
    parts.context.applyFreshTiresOnVehId(vehId, parts.context.buildInitialWheelState(inventoryId, vehicleData))
  end
  return true
end

-- Game hooks: vehicles -----------------------------------------------------------------------------

function M.onVehicleSpawned(_, vehObj)
  if vehObj then
    lastContextSignatures[vehObj:getID()] = nil
    M.sendContextForVehicle(vehObj:getID(), true)
  end
end

function M.onVehicleSwitched(oldId, newVehId)
  local oldVehId = tonumber(oldId)
  local oldVeh = oldVehId and getObjectByID(oldVehId) or nil
  if oldVeh then
    oldVeh:queueLuaCommand("if overhaulTires then " .. vehicleCommands.call("overhaulTires", "flushState") .. "; "
    .. vehicleCommands.call("overhaulTires", "resetThermalsAndGrip") .. " end")
  end
  local owner = newVehId and runtimeOwnersByVehId[tonumber(newVehId)] or nil
  if owner and owner.kind == "business" then
    M.sendContextForBusinessVehicle(owner.businessId, owner.vehicleId, true)
  elseif newVehId then
    M.sendContextForVehicle(newVehId, true)
  end
end

function M.onOverhaulVehicleRemoved(inventoryId, vehId)
  local vehObj = vehId and getObjectByID(tonumber(vehId)) or nil
  if vehObj then vehObj:queueLuaCommand(FLUSH_COMMAND) end
  if vehId then
    runtimeOwnersByVehId[tonumber(vehId)] = nil
    lastContextSignatures[tonumber(vehId)] = nil
    parts.context.contextTraces[tonumber(vehId)] = nil
    parts.context.configuredRest[tonumber(vehId)] = nil
  end
end

function M.onOverhaulInventoryPreRemoveVehicleObject(inventoryId, vehId)
  vehId = tonumber(vehId)
  local vehObj = vehId and getObjectByID(vehId) or nil
  if vehObj then
    vehObj:queueLuaCommand(FLUSH_AND_RESET_COMMAND)
  end
  if vehId then
    runtimeOwnersByVehId[vehId] = nil
    lastContextSignatures[vehId] = nil
    parts.context.contextTraces[vehId] = nil
    parts.context.configuredRest[vehId] = nil
  end
end

function M.onOverhaulPartShoppingStarted()
  local inventoryId = overhaul_career_garage_inventory.getCurrentVehicle() or nil
  local vehId = inventoryId and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
  local vehObj = vehId and getObjectByID(vehId) or nil
  if vehObj then vehObj:queueLuaCommand(FLUSH_COMMAND) end
  local vehicleData = inventoryId and vehicleDataForInventory(inventoryId) or nil
  for _, wheel in ipairs(vehicleData and vehicleData.rlsTireLayout and vehicleData.rlsTireLayout.wheels or {}) do
    local _, part = findPersonalPart(inventoryId, wheel.partPath, wheel.partOrigin, wheel.containingSlot)
    if part then
      local wheelState = ensurePartWheelState(part, wheel.name, vehicleData)
      wheelState.remaining = tireModel.clamp(wheel.remaining, 0, 1)
      wheelState.flat = wheel.flat == true
      setPartState(part, partState(part))
    end
  end
end

local function installedPartMatchesWheel(descriptor, wheel)
  if descriptor.partPath and wheel.partPath == descriptor.partPath then
    return true
  end
  return descriptor.containingSlot and wheel.containingSlot == descriptor.containingSlot
end

function M.onOverhaulPartShoppingPartsInstalled(inventoryId, installedParts)
  inventoryId = tonumber(inventoryId)
  local vehicleData = inventoryId and vehicleDataForInventory(inventoryId) or nil
  if not vehicleData or type(installedParts) ~= "table" then return end

  local changed = false
  for _, descriptor in ipairs(installedParts) do
    local lowerName = string.lower(tostring(descriptor.name or ""))
    if string.sub(lowerName, 1, 5) == "tire_" then
      local _, part = findPersonalPart(inventoryId, descriptor.partPath, descriptor.name,
        descriptor.containingSlot)
      if part then
        for _, wheel in ipairs(vehicleData.rlsTireLayout and vehicleData.rlsTireLayout.wheels or {}) do
          if installedPartMatchesWheel(descriptor, wheel) then
            local wheelState = ensurePartWheelState(part, wheel.name, vehicleData,
              descriptor.fromInventory ~= true)
            wheel.remaining = wheelState.remaining
            wheel.flat = wheelState.flat
            changed = true
          end
        end
      end
    end
  end

  if changed then
    maybeInvalidateInspection(vehicleData)
    markDirty(inventoryId)
  end
end

-- Game hooks: contexts -----------------------------------------------------------------------------

function M.onOverhaulExperimentalMaintenanceModeChanged()
  parts.context.sendAllContexts(true)
end

function M.onTrailerAttached()
  parts.context.sendAllContexts(true)
end

function M.onOverhaulPartShoppingTransactionComplete()
  for inventoryId in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
    -- Skip non-numeric ids (e.g. offroadRecovery:job-...) — partRevisions is keyed by number.
    local id = tonumber(inventoryId)
    if id then
      partRevisions[id] = (tonumber(partRevisions[id]) or 0) + 1
    end
  end
  parts.context.sendAllContexts(true)
end

function M.onCheatVehicleRecovered(inventoryId)
  return M.forceFreshForVehicle(inventoryId)
end

return M
