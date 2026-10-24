-- Vehicle callbacks and controller commands across spawn, destroy and career transitions.
-- Read state, controller commands and patch lifecycle, then the public API and game hooks.
local M = {}
local vehicleCommands = require('overhaul/lib/vehicles/vehicleCommands')
local vehicleCallbacks = require('overhaul/lib/vehicles/callbacks')
local vehicleRoles = require('common/overhaul/vehicleRoles')
M.dependencies = {'overhaul_shell_patches'}

local patchRegistry
local registered = false
local active = false
local generation = math.floor(os.clock() * 1000000)
local vehicles = {}
local installBridge, uninstallBridge, refreshBridge
local serviceLookups = {
  overhaulGetCargoContainers = true,
  getOverhaulInventoryVehicleState = true,
  getOverhaulMechanismRestoreState = true,
}
local serviceActions = {overhaulSetCargoContainers = true}

local function queue(vehicle, enabled)
  if not vehicle then return end
  local id = vehicle:getID()
  vehicles[id] = true
  local command = vehicleCommands.call('overhaulPlayerControllerManager',
    vehicleRoles.lookup({servicesEnabled = enabled}).controllerCommand, generation)
  vehicle:queueLuaCommand("extensions.load('overhaulPlayerControllerManager'); extensions." .. command)
end

local function ensureServices(vehicle)
  if active and vehicle and not vehicles[vehicle:getID()] then queue(vehicle, true) end
end

local function enablePlayer()
  ensureServices(be:getPlayerVehicle(0))
end

local function install()
  active = true
  generation = math.max(generation + 1, math.floor(os.clock() * 1000000))
  installBridge()
  enablePlayer()
end

local function uninstall()
  active = false
  uninstallBridge()
  generation = math.max(generation + 1, math.floor(os.clock() * 1000000))
  for id in pairs(vehicles) do queue(be:getObjectByID(id), false) end
  vehicles = {}
end

local function refresh()
  if not active then return end
  refreshBridge()
  enablePlayer()
end

function M.onVehicleSpawned(id)
  if not active then return end
  local vehicle = be:getObjectByID(id)
  if vehicles[id] or vehicle == be:getPlayerVehicle(0) then queue(vehicle, true) end
end

function M.onVehicleSwitched(_, id)
  ensureServices(be:getObjectByID(id))
end

function M.onVehicleDestroyed(id)
  vehicles[id] = nil
  vehicleCallbacks.vehicleChanged(id, "destroyed")
end

function M.onVehicleReplaced(id)
  vehicleCallbacks.vehicleChanged(id, "replaced")
end

function M.onOverhaulBeforeCareerActivate()
  vehicleCallbacks.advanceCareerEpoch("started")
end

function M.onOverhaulActive(isActive)
  if not isActive then vehicleCallbacks.advanceCareerEpoch("stopped") end
end

function M.onExtensionLoaded()
  if registered then return end
  patchRegistry = overhaul_shell_patches
  -- The enable command reaches VE before the bridge request queued behind it.
  -- Cargo trailers and job vehicles therefore need no spawn-time installation.
  installBridge, uninstallBridge, refreshBridge = patchRegistry.fieldSwap(
    patchRegistry.onDemandExtension('core_vehicleBridge'), {
      requestValue = function(original)
        return function(vehicle, callback, key, ...)
          if serviceLookups[key] then ensureServices(vehicle) end
          return original(vehicle, callback, key, ...)
        end
      end,
      executeAction = function(original)
        return function(vehicle, key, ...)
          if serviceActions[key] then ensureServices(vehicle) end
          return original(vehicle, key, ...)
        end
      end,
    })
  patchRegistry.register('vehicleControllersAndCargo', install, uninstall, refresh)
  registered = true
end

function M.onExtensionUnloaded()
  if registered then patchRegistry.unregister('vehicleControllersAndCargo') end
  registered = false
end

return M
