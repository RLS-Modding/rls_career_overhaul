-- Routes traffic to owned services, then restores stock methods and cached police getters.
-- Owns service activation, traffic adoption, reversible class bindings and level refresh.
local M = {}

local wrapperLifetime = require("overhaul/lib/shell/wrapperLifetime")
local trafficVehicleMethods = require("overhaul/integration/ownedServices/trafficVehicle")
local policeRole = require("overhaul/integration/ownedServices/trafficPoliceRole")

M.dependencies = {'overhaul_shell_patches', 'gameplay_traffic', 'overhaul_integration_services_parking', 'overhaul_integration_services_police', 'overhaul_integration_services_speedTraps'}

local methodNames = {
  'init', 'resetPursuit', 'resetValues', 'resetElectrics', 'honkHorn', 'useSiren', 'setAiMode',
  'setAiParameters', 'setRole', 'checkCollisions', 'fade', 'tryRespawn', 'triggerOffense',
  'checkOffenses', 'checkPoliceVisibility', 'onVehicleResetted', 'onTrafficTick', 'onPursuitUpdate',
  'onUpdate', 'onSerialize', 'onDeserialized'
}

local installed = false
local registered = false
local patchRegistry
local wrappers = {}
local adoptedVehicles = setmetatable({}, {__mode = 'k'})
local patchedClasses = setmetatable({}, {__mode = 'k'})
local vanillaParking, vanillaPolice
local parkingState, policeState

local function active()
  return installed and overhaul_shell_gameMode and overhaul_shell_gameMode.isActive()
end

local function bind(item, target)
  if type(target[item.name]) ~= "function" then error("Missing gameplay service function: " .. item.name) end
  local handler, directImplementation = item.fn, item.direct
  local binding = wrapperLifetime.prepare(target, item.name, function(original, _, state)
    if item.silent then return nil, true end
    -- Installing the owned class method directly avoids a relay on every traffic frame.
    if directImplementation then return directImplementation, true end
    return function(...)
      if state.active and active() then return handler(original, ...) end
      return original(...)
    end, true
  end)
  item.binding = binding
  wrapperLifetime.install(binding)
end

-- Remember the module name so level loads can replace its wrapped instance.
local function wrap(target, name, handler, moduleName, directImplementation)
  local item = {name = name, fn = handler, global = moduleName, direct = directImplementation}
  bind(item, target)
  wrappers[#wrappers + 1] = item
end

local function silence(target, name, moduleName)
  local item = {name = name, global = moduleName, silent = true}
  bind(item, target)
  wrappers[#wrappers + 1] = item
end

-- Cached direct getters avoid a service guard on every traffic frame.

local function ownedPoliceGetters()
  local police = overhaul_integration_services_police
  return police.getDirect and police.getDirect('getPolice') or police.getPolice,
    police.getDirect and police.getDirect('getPoliceVars') or police.getPoliceVars
end

local function refreshPoliceRole(veh)
  if not veh.role or veh.role.name ~= 'police' or not getObjectByID(veh.id) then return end
  local data = veh.role:onSerialize()
  veh:setRole('police')
  veh.role:onDeserialized(data, veh)
end

local function adoptVehicle(veh)
  if not active() or not veh then return end
  local class = getmetatable(veh)
  if type(class) ~= 'table' then return end
  if not patchedClasses[class] then
    patchedClasses[class] = true
    for _, name in ipairs(methodNames) do
      local implementation = trafficVehicleMethods[name]
      wrap(class, name, function(_, ...) return implementation(...) end, nil, implementation)
    end
  end
  if not adoptedVehicles[veh] then
    local state = {
      getPolice = veh.getPolice == overhaul_integration_services_police.getPolice and vanillaPolice.getPolice or veh.getPolice,
      getPoliceVars = veh.getPoliceVars == overhaul_integration_services_police.getPoliceVars and vanillaPolice.getPoliceVars or veh.getPoliceVars
    }
    if type(state.getPolice) ~= 'function' or type(state.getPoliceVars) ~= 'function' then
      error('Traffic vehicle has no cached police getters: ' .. tostring(veh.id))
    end
    state.police, state.vars = ownedPoliceGetters()
    adoptedVehicles[veh] = state
    veh.getPolice, veh.getPoliceVars = state.police, state.vars
    refreshPoliceRole(veh)
  end
end

local function adoptTraffic()
  for _, veh in pairs(gameplay_traffic.getTrafficData()) do adoptVehicle(veh) end
end

local function refreshHooks()
  for _, name in ipairs({'onUpdate', 'onVehicleSwitched', 'onVehicleResetted', 'onSerialize', 'onDeserialized', 'onBeamNGTrigger', 'onTrafficSpecialVehiclesProviders', 'onVehicleGroupSpawned'}) do
    extensions.hookUpdate(name)
  end
end

local function enableServices()
  if installed then return end
  vanillaParking, vanillaPolice = gameplay_parking, gameplay_police
  parkingState = vanillaParking.onSerialize()
  policeState = vanillaPolice.onSerialize()
  installed = true
  overhaul_integration_services_parking.enable(parkingState)
  overhaul_integration_services_police.enable(policeState)
  overhaul_integration_services_speedTraps.enable()
end

local function bindParkingAndPolice()
  wrap(vanillaParking, 'setupVehicles', function(_, ...) return overhaul_integration_services_parking.setupVehicles(...) end, 'gameplay_parking')
  wrap(vanillaParking, 'getState', function() return overhaul_integration_services_parking.getState() end, 'gameplay_parking')
  -- The owned parking spawns the "autoParking" group; the game's parking must not adopt it.
  wrap(vanillaParking, 'onVehicleGroupSpawned', function() end, 'gameplay_parking')
  for _, name in ipairs({'getParkedCarsList', 'getParkedCarsData', 'getParkedCarsAmount', 'deleteVehicles'}) do
    wrap(vanillaParking, name, function(_, ...) return overhaul_integration_services_parking[name](...) end, 'gameplay_parking')
  end
  wrap(vanillaParking, 'onSerialize', function() return deepcopy(parkingState) end, 'gameplay_parking')
  wrap(vanillaPolice, 'onSerialize', function() return deepcopy(policeState) end, 'gameplay_police')
  wrap(vanillaParking, 'onDeserialized', function() end, 'gameplay_parking')
  wrap(vanillaPolice, 'onDeserialized', function() end, 'gameplay_police')
  silence(vanillaPolice, 'onUpdate', 'gameplay_police')
  for _, name in ipairs({'onVehicleSwitched', 'onVehicleResetted', 'onTrafficSpecialVehiclesProviders'}) do
    wrap(vanillaPolice, name, function() end, 'gameplay_police')
  end
  for _, name in ipairs({'setPursuitMode', 'evadeVehicle', 'getNearestPoliceVehicle'}) do
    wrap(vanillaPolice, name, function(_, ...) return overhaul_integration_services_police[name](...) end, 'gameplay_police')
  end
end

local function bindTraffic()
  wrap(gameplay_traffic_trafficUtils, 'getRoleConstructor', function(original, name, ...)
    if name == 'police' then return policeRole end
    return original(name, ...)
  end, 'gameplay_traffic_trafficUtils')
  wrap(gameplay_traffic, 'freezeState', function(_, options)
    local traffic = gameplay_traffic.onSerialize(options)
    local police = overhaul_integration_services_police.onSerialize()
    local parking = overhaul_integration_services_parking.onSerialize(options)
    return traffic, police, parking
  end, 'gameplay_traffic')
  wrap(gameplay_traffic, 'unfreezeState', function(_, traffic, police, parking, options)
    if traffic then
      gameplay_traffic.onDeserialized(traffic, options)
      adoptTraffic()
      gameplay_traffic.scatterTraffic()
    end
    if police then overhaul_integration_services_police.onDeserialized(police) end
    if parking then overhaul_integration_services_parking.onDeserialized(parking, options) end
  end, 'gameplay_traffic')
  adoptTraffic()
  overhaul_integration_services_police.onTrafficSpecialVehiclesProviders()
  refreshHooks()
end

local function install()
  if installed then return end
  enableServices()
  bindParkingAndPolice()
  bindTraffic()
end

-- Level loads replace the game's traffic modules; wrap the copies that are live now.
local function refresh()
  if not installed then return end
  local changed = false
  for _, item in ipairs(wrappers) do
    local liveModule = item.global and rawget(_G, item.global)
    if liveModule and (liveModule ~= item.binding.target or not wrapperLifetime.intact(item.binding)) and type(liveModule[item.name]) == 'function' then
      wrapperLifetime.retire(item.binding)
      bind(item, liveModule)
      changed = true
    end
  end
  if changed then
    vanillaParking, vanillaPolice = gameplay_parking, gameplay_police
    refreshHooks()
  end
end

local function uninstall()
  installed = false
  for index = #wrappers, 1, -1 do
    local item = wrappers[index]
    wrapperLifetime.retire(item.binding)
  end
  table.clear(wrappers)
  table.clear(patchedClasses)
  for veh, state in pairs(adoptedVehicles) do
    if veh.getPolice == state.police then veh.getPolice = state.getPolice end
    if veh.getPoliceVars == state.vars then veh.getPoliceVars = state.getPoliceVars end
    refreshPoliceRole(veh)
  end
  table.clear(adoptedVehicles)
  local parking = overhaul_integration_services_parking.disable() or parkingState
  local police = overhaul_integration_services_police.disable() or policeState
  overhaul_integration_services_speedTraps.disable()
  if vanillaParking and parking then vanillaParking.onDeserialized(parking) end
  if vanillaPolice and police then
    police.vars = policeState and policeState.vars or police.vars
    vanillaPolice.onDeserialized(police)
    for id in pairs(gameplay_traffic.getTrafficData()) do vanillaPolice.onTrafficVehicleAdded(id) end
    vanillaPolice.onTrafficSpecialVehiclesProviders()
  end
  vanillaParking, vanillaPolice, parkingState, policeState = nil, nil, nil, nil
  refreshHooks()
end

function M.onExtensionLoaded()
  if registered then return end
  patchRegistry = overhaul_shell_patches
  patchRegistry.register('gameplayServices', install, uninstall, refresh)
  -- gameplay_speedTraps is a level preset; the owned speed traps replace each copy a level loads.
  patchRegistry.registerFields('speedTrapTriggers', function() return rawget(_G, 'gameplay_speedTraps') end, {
    onBeamNGTrigger = function(original)
      return function(...)
        if active() then return end
        return original(...)
      end
    end,
  })
  registered = true
end

function M.onTrafficStarted()
  if active() then adoptTraffic() end
end

function M.onTrafficVehicleAdded(id)
  if active() then adoptVehicle(gameplay_traffic.getTrafficData()[id]) end
end

function M.isInstalled()
  return installed
end

function M.onExtensionUnloaded()
  if registered then
    patchRegistry.unregister('speedTrapTriggers')
    patchRegistry.unregister('gameplayServices')
  end
  registered = false
  patchRegistry = nil
end

return M
