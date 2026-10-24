-- Business part customization: the preview session, rollback when the business computer closes, and the public API.
-- The work lives in the part files under partCustomization/; this file builds them once per load and shares their session state.
local M = {}
local customizationAccess = require('overhaul/lib/business/customizationAccess')

local jbeamIO = require('jbeam/io')
local jbeamSlotSystem = require('jbeam/slotSystem')

-- The current preview session and the power/weight requests in flight, shared by the part files (not saved).
local runtime = {
  currentSession = nil,
  pendingPowerRequests = {},
  pendingPowerRequestCount = 0,
}
local parts = {}

local function sessionMatches(businessId, vehicleId)
  if not runtime.currentSession then
    return false
  end
  if tostring(runtime.currentSession.businessId) ~= tostring(businessId) then
    return false
  end
  if vehicleId and tostring(runtime.currentSession.vehicleId) ~= tostring(vehicleId) then
    return false
  end
  return true
end

local function getActiveSession(businessId)
  if sessionMatches(businessId) then
    return runtime.currentSession
  end
  return nil
end

local function resetCurrentSession()
  parts.buildOperation.cancelCurrent('Preview session cleared')
  if runtime.currentSession then parts.conditions.release(runtime.currentSession) end
  runtime.currentSession = nil
end

-- The parts read siblings through this load's table; sessions and callbacks stay isolated on reload.
parts.session = {
  sessionMatches = sessionMatches,
  getActiveSession = getActiveSession,
  resetCurrentSession = resetCurrentSession,
}
local inputs = {
  parts = parts, runtime = runtime, owner = M,
  jbeamIO = jbeamIO, jbeamSlotSystem = jbeamSlotSystem,
  isOwnerCurrent = function() return overhaul_career_business_partCustomization == M end,
}
for _, name in ipairs({"baseline", "preview", "cart", "cartBuild", "buildOperation", "conditions"}) do
  parts[name] = require("overhaul/career/business/partCustomization/" .. name).new(inputs)
end

-- Vehicles bought or changed in the business computer read power without the dyno gate.
local function requestVehiclePowerWeightAfterPurchase(businessId, vehicleId)
  if not businessId or vehicleId == nil then
    return false
  end
  local vehObj = parts.baseline.getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return false
  end
  parts.baseline.requestVehiclePowerWeight(vehObj, businessId, vehicleId, true)
  return true
end

local function invalidateAndRequestVehiclePowerWeight(businessId, vehicleId)
  if not businessId or vehicleId == nil then
    return false
  end
  if sessionMatches(businessId, vehicleId) and runtime.currentSession then
    runtime.currentSession.powerWeight = nil
  end
  local vehObj = parts.baseline.getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return false
  end
  parts.baseline.requestVehiclePowerWeight(vehObj, businessId, vehicleId)
  return true
end

local rollbackOnUiCloseInProgress = false

-- Recover a missing car, then let discard invalidate queued preview work.
local function sessionIdleForRollback()
  if rollbackOnUiCloseInProgress or not runtime.currentSession then
    return false
  end
  if runtime.currentSession.operationInProgress then
    parts.cartBuild.tryEmergencyRestoreSessionVehicle(runtime.currentSession.businessId, runtime.currentSession.vehicleId)
  end
  return true
end

local function rollbackOpenSession()
  rollbackOnUiCloseInProgress = true
  local businessId = runtime.currentSession.businessId
  parts.cartBuild.clearPreviewVehicle(businessId)
  rollbackOnUiCloseInProgress = false
end

local function onUIPlayStateChanged(enteredPlay)
  if not enteredPlay then
    return
  end
  parts.buildOperation.cancelCurrent('Business computer closed')
  if sessionIdleForRollback() then
    rollbackOpenSession()
  end
end

local function onUiChangedState(toState, fromState)
  if fromState == 'business-computer' and toState ~= 'business-computer' then
    parts.buildOperation.cancelCurrent('Business computer closed')
  end
  if sessionIdleForRollback() and fromState == 'business-computer' and toState ~= 'business-computer' then
    rollbackOpenSession()
  end
end

local function onUIInitialised()
  parts.buildOperation.cancelCurrent('UI restarted')
  if sessionIdleForRollback() then
    rollbackOpenSession()
  end
end

M.onPowerWeightReceived = parts.cart.onPowerWeightReceived
M.requestVehiclePowerWeightAfterPurchase = requestVehiclePowerWeightAfterPurchase
M.invalidateAndRequestVehiclePowerWeight = invalidateAndRequestVehiclePowerWeight
M.initializePreviewVehicle = parts.preview.initializePreviewVehicle
M.resetVehicleToOriginal = parts.preview.resetVehicleToOriginal
M.applyPartsToVehicle = function(businessId, vehicleId, ...)
  if not customizationAccess.allow(businessId, vehicleId) then return false end
  return parts.preview.applyPartsToVehicle(businessId, vehicleId, ...)
end
M.applyCartPartsToVehicle = function(businessId, vehicleId, cart, onComplete, ...)
  if not customizationAccess.allow(businessId, vehicleId) then
    if onComplete then onComplete(false) end
    return false
  end
  return parts.cart.applyCartPartsToVehicle(businessId, vehicleId, cart, onComplete, ...)
end
M.installPartOnVehicle = parts.cart.installPartOnVehicle
M.getVehiclePowerWeight = parts.cart.getVehiclePowerWeight
M.getPreviewVehicleConfig = parts.cart.getPreviewVehicleConfig
M.updatePreviewVehicleConfig = parts.cart.updatePreviewVehicleConfig
M.getInitialVehicleState = parts.cart.getInitialVehicleState
M.commitSessionInitialFromPreview = parts.cart.commitSessionInitialFromPreview
M.commitSessionTuning = parts.cart.commitSessionTuning
M.capturePreviewConditions = function(businessId, vehicleId, onDone)
  local session = parts.preview.ensureActiveSession(businessId, vehicleId)
  if not session then onDone(false); return end
  parts.conditions.capture(session, onDone)
end
M.applyPreviewConditions = function(businessId, vehicleId, vehObj, config)
  local session = getActiveSession(businessId)
  if not session or not sessionMatches(businessId, vehicleId) then return false end
  return parts.conditions.apply(session, vehObj, config)
end
M.clearPreviewVehicle = parts.cartBuild.clearPreviewVehicle
-- Direct paid replacements wait until any unpaid preview has restored its baseline.
M.settlePreviewVehicle = function()
  if runtime.currentSession then parts.cartBuild.clearPreviewVehicle(runtime.currentSession.businessId) end
  return runtime.currentSession == nil
end
M.getAllRequiredParts = parts.preview.getAllRequiredParts
M.addPartToCart = function(businessId, vehicleId, cart, ...)
  if not customizationAccess.allow(businessId, vehicleId) then return cart or {} end
  return parts.cartBuild.addPartToCart(businessId, vehicleId, cart, ...)
end
M.findRemovedParts = parts.cartBuild.findRemovedParts
M.onUIPlayStateChanged = onUIPlayStateChanged
M.onUiChangedState = onUiChangedState
M.onUIInitialised = onUIInitialised
M.applyBuildToVehicle = function(businessId, vehicleId, build, operationId)
  if not customizationAccess.allow(businessId, vehicleId) then
    guihooks.trigger('businessComputer:onBuildOperationCompleted', {
      businessId = businessId, vehicleId = vehicleId, operationId = operationId,
      success = false, reason = 'Repair the vehicle first', nonce = operationId,
    })
    return false
  end
  return parts.buildOperation.applyBuildToVehicle(businessId, vehicleId, build, operationId)
end
M.cancelBuildOperation = parts.buildOperation.cancelBuildOperation
M.onBuildVehicleCommandResult = parts.buildOperation.onBuildVehicleCommandResult
M.hasNewerOwnedPreviewForVehicle = parts.buildOperation.hasNewerOwnedPreviewForVehicle
M.onUpdate = parts.buildOperation.onUpdate
local function closeOwner(reason)
  parts.buildOperation.cancelCurrent(reason)
  -- Teardown cannot queue work against the next map/profile's vehicle.
  resetCurrentSession()
end
M.onExtensionUnloaded = function() closeOwner('Preview module unloaded') end
M.onOverhaulBeforeSetProfile = function() closeOwner('Profile changed') end
M.onOverhaulActive = function(active) if not active then closeOwner('Career deactivated') end end

return M
