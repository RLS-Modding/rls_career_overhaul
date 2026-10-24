-- Hands the taxi, marker and walking-marker hooks to Overhaul's services while Overhaul runs.
-- Stock hooks are suppressed or bridged through the shell patch registry and restored on exit.
local M = {}
M.dependencies = {"overhaul_shell_patches", "overhaul_integration_services_markerInteraction", "gameplay_taxi", "gameplay_markerInteraction", "gameplay_playmodeMarkers"}

local registered = false
local patchRegistry
local swap = {}
local walkingFactory = require('overhaul/lib/ui/walkingMarker')

local function isActive()
  return overhaul_shell_gameMode and overhaul_shell_gameMode.isActive() == true
end

local function stockFunction(original, name)
  if type(original) ~= 'function' then error('Missing stock bridge: ' .. name) end
  return original
end

local function live(name)
  return function() return rawget(_G, name) end
end

-- Per-frame hooks are removed from the game module while Overhaul runs, so the hook dispatch skips it.
local PER_FRAME = {onUpdate = true, onPreRender = true}

-- Overhaul's wrapper returns nothing while active; the game's hook runs only when Overhaul is off.
local function suppress(wrappers, names)
  for _, name in ipairs(names) do
    wrappers[name] = function(original)
      stockFunction(original, name)
      if PER_FRAME[name] then return nil end
      return function(...)
        if isActive() then return end
        return original(...)
      end
    end
  end
  return wrappers
end

-- Overhaul's service answers the call while active; the game's hook runs otherwise.
local function bridge(wrappers, owner, names)
  for _, name in ipairs(names) do
    wrappers[name] = function(original)
      stockFunction(original, name)
      return function(...)
        if isActive() then return owner()[name](...) end
        return original(...)
      end
    end
  end
  return wrappers
end

local function taxiService()
  return overhaul_integration_services_taxi
end

local function markerService()
  return overhaul_integration_services_markerInteraction
end

local TAXI_SUPPRESSED_HOOKS = {
  'onUpdate', 'onTrafficSpecialVehiclesProviders', 'onTrafficStarted', 'onTrafficVehicleAdded',
  'onTrafficVehicleRemoved', 'onTrafficStopped', 'onAnyMissionChanged', 'onTrafficVehicleCrashed',
  'onVehicleResetted', 'onVehicleSwitched', 'onGameplayInteract', 'onVehicleTriggersExecuteLink',
  'onRegisterQuickAccessMenus', 'onAiRouteDone', 'onSetBigmapNavFocus', 'onDeactivateBigMapCallback',
  'onClientEndMission',
}
local TAXI_BRIDGED_CALLS = {
  'onTaxiViewEnter', 'onHurryUpCalled', 'onSlowDownCalled', 'onSkipCalled', 'onChangeDestinationCalled',
  'onStopTaxiCalled', 'setIdleCameraEnabled', 'confirmTaxiDestination', 'isTaxiRideActive', 'taxiSettingChanged',
}
local MARKER_SUPPRESSED_HOOKS = {
  'onPreRender', 'onSettingsChanged', 'onNavigateToMission', 'onAnyMissionChanged',
  'onClientEndMission', 'onUIPlayStateChanged',
}
local MARKER_BRIDGED_CALLS = {
  'getGameContext', 'getCurrentInteractableElements', 'clearCache',
  'skipNextIconFading', 'setMarkersVisibleTemporary', 'setForceReevaluateOpenPrompt',
}

local taxiWrappers = bridge(suppress({}, TAXI_SUPPRESSED_HOOKS), taxiService, TAXI_BRIDGED_CALLS)

local markerWrappers = bridge(suppress({}, MARKER_SUPPRESSED_HOOKS), markerService, MARKER_BRIDGED_CALLS)

local function wrapCloseViewDetailPrompt(original)
  stockFunction(original, 'closeViewDetailPrompt')
  return function(...)
    if isActive() then return markerService().dismissViewDetailPrompt() end
    return original(...)
  end
end
markerWrappers.closeViewDetailPrompt = wrapCloseViewDetailPrompt

-- Build garage discovery into clusters so per-frame marker lookup can use the stock function directly.
local STOCK_WALKING = 'lua/ge/extensions/gameplay/markers/walkingMarker'

local function stockWalkingFactory()
  return require(STOCK_WALKING)
end

-- A door shared by several facilities discovers the first garage among them.
local function garageIdFromElements(cluster)
  for _, elem in ipairs(cluster.elemData or {}) do
    local facility = elem.facility
    if facility and facility.garageId then return facility.garageId end
  end
end

local function assignDiscoveredGarageIds(allClusters, firstIndex)
  for index = firstIndex, #allClusters do
    local cluster = allClusters[index]
    if cluster.garageId == nil then cluster.garageId = garageIdFromElements(cluster) end
  end
end

local function wrapWalkingCluster(original)
  stockFunction(original, 'walkingMarker.cluster')
  return function(pois, allClusters, ...)
    if not isActive() then return original(pois, allClusters, ...) end
    local first = #allClusters + 1
    walkingFactory.cluster(pois, allClusters, ...)
    assignDiscoveredGarageIds(allClusters, first)
  end
end

local walkingWrappers = {cluster = wrapWalkingCluster}

local function install()
  swap.install()
  gameplay_playmodeMarkers.clear()
  taxiService().onTrafficSpecialVehiclesProviders()
  taxiService().onTrafficStarted()
  taxiService().onRegisterQuickAccessMenus()
  markerService().onSettingsChanged()
end

local function uninstall()
  taxiService().disable()
  markerService().disable()
  swap.uninstall()
  gameplay_playmodeMarkers.clear()
  if gameplay_taxi.onTrafficSpecialVehiclesProviders then gameplay_taxi.onTrafficSpecialVehiclesProviders() end
  if gameplay_taxi.onTrafficStarted then gameplay_taxi.onTrafficStarted() end
  -- Overhaul's Other > Call Taxi entry shares the game's id; give the slot back.
  if gameplay_taxi.onRegisterQuickAccessMenus then gameplay_taxi.onRegisterQuickAccessMenus() end
end

local function registerSwaps()
  patchRegistry = overhaul_shell_patches
  swap.install, swap.uninstall, swap.refresh = patchRegistry.fieldSwaps({
    {live('gameplay_taxi'), taxiWrappers},
    {live('gameplay_markerInteraction'), markerWrappers},
    {stockWalkingFactory, walkingWrappers},
  })
  patchRegistry.register('taxiMarkers', install, uninstall, swap.refresh)
end

function M.onExtensionLoaded()
  if registered then return end
  registerSwaps()
  registered = true
end

function M.onExtensionUnloaded()
  if registered then patchRegistry.unregister('taxiMarkers') end
  registered = false
end

return M
