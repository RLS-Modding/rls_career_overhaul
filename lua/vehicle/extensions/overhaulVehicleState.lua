-- Inventory state travels in one reply so pose and conditions belong to the same capture frame.
-- The career vehicle manager loads this module by name; gameplayInterface owns its replies.
local M = {moduleActions={},moduleLookups={}}
local active = false
local registered = false

local function inventoryState()
  if not active then return {failReason='Vehicle state is inactive'} end
  extensions.load('overhaulDamageState')
  return {result={format='overhaul_inventory_state_v1',partConditions=partCondition.getConditions(),
    mechanismState=overhaulDamageState.captureMechanismState()}}
end

function M.onExtensionLoaded()
  M.moduleLookups.getOverhaulInventoryVehicleState = inventoryState
  M.moduleLookups.getOverhaulMechanismRestoreState = function()
    if not active then return {failReason='Vehicle state is inactive'} end
    return {result=overhaulDamageState and overhaulDamageState.getMechanismRestoreState() or {complete=true}}
  end
end

function M.requestRegistration(interface)
  interface.registerModule('overhaulVehicleState',M.moduleActions,M.moduleLookups)
  registered = true
end

function M.setActive(enabled)
  if enabled and not registered then
    local interface = extensions.gameplayInterface
    if not interface or not interface.registerModule then return false end
    M.requestRegistration(interface)
  end
  active = enabled == true
  return true
end

M.onExtensionUnloaded = function() active = false; registered = false end

return M
