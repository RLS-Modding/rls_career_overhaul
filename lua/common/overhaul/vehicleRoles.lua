-- Descriptive vehicle roles and the existing loader decisions, without game state.
-- Fresh results keep the require-cached provider independent of each vehicle session.
local M = {}

local kinds = {
  ownedDriven = {inventory = 'owned'}, ownedParked = {inventory = 'owned'},
  loaner = {inventory = 'issued'}, company = {inventory = 'issued'}, work = {inventory = 'issued'},
  business = {inventory = 'business'}, issued = {inventory = 'issued'},
  inspection = {}, walkingAvatar = {}, race = {}, derby = {}, suspect = {},
  traffic = {}, parkedTraffic = {}, unknown = {},
}

local function roleName(facts)
  if kinds[facts.kind] then return facts.kind end
  local vehicle = facts.inventoryVehicle
  if vehicle then
    if vehicle.loanType == 'company' or vehicle.loanType == 'work' then return vehicle.loanType end
    if vehicle.loanType then return 'loaner' end
    if vehicle.owned then return facts.playerDriven and 'ownedDriven' or 'ownedParked' end
    return 'issued'
  end
  if facts.trafficRole == 'suspect' then return 'suspect' end
  if facts.parkedTraffic then return 'parkedTraffic' end
  if facts.trafficRole then return 'traffic' end
  return 'unknown'
end

function M.lookup(facts)
  facts = facts or {}
  local vehicle = facts.inventoryVehicle
  -- Keep Lua truthiness (including 0 and empty strings), not an owned == true test.
  local ownedExtensions = not not (vehicle and vehicle.owned and not vehicle.loanType and not vehicle.listedForAuction)
  local services = not not facts.servicesEnabled
  return {
    role = roleName(facts),
    controllerCommand = services and 'enable' or 'disable',
    controllerManager = services, cargoBridge = services, gearGuard = services,
    ownedFuelMultiplier = ownedExtensions, ownedAI = ownedExtensions,
    -- Spawn dispatch still gives inventory bindings priority at the caller, even for loaners.
    spawnTrafficAI = facts.trafficRole == 'suspect',
    -- Keep the saved maintenance mode independent of role-specific bridge loading and cleanup.
    maintenanceModeEnabled = not facts.maintenanceGated or facts.maintenanceEnabled == true,
  }
end

function M.getKinds()
  local result = {}
  for name, data in pairs(kinds) do result[name] = {inventory = data.inventory} end
  return result
end

return M
