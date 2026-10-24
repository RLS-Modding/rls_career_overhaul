-- Routes stock listeners to owned score, statistic and garage services during Overhaul.
-- Owns reversible listener bindings, level refresh and rich presence, resolved from provider declarations.
local M = {}

local optional = require('overhaul/lib/platform/optional')
local wrapperLifetime = require("overhaul/lib/shell/wrapperLifetime")
local catalog = require("overhaul/lib/platform/catalog")
-- The crawl, drag and speed trap modules are level presets; they are wrapped each time a level loads them.
M.dependencies = {
  "overhaul_shell_patches", "overhaul_integration_services_crawlScores", "overhaul_integration_services_dragScores",
  "overhaul_integration_services_statistic", "overhaul_integration_services_garageMode"
}

local PRESENCE_ACTIVITIES_DIR = "/gameplay/overhaul/presenceActivities/"

local registered = false
local patchRegistry
local installed = {}
local levelPatches = {}
local restoreForceField = false

local function isActive()
  return (overhaul_shell_gameMode and overhaul_shell_gameMode.isActive())
    or (overhaul_career_career and overhaul_career_career.isActive()) or false
end

local function bind(item, target)
  if not target or type(target[item.name]) ~= "function" then error("Missing listener API: " .. item.name) end
  local handler = item.handler
  local binding = wrapperLifetime.prepare(target, item.name, function(original, _, state)
    return function(...)
      if state.active and isActive() then return handler(original, ...) end
      return original(...)
    end, true
  end, {notify = extensions.hookUpdate})
  item.binding = binding
  wrapperLifetime.install(binding)
end

-- Remember the module name so level loads can replace its wrapped instance.
local function wrap(moduleName, name, handler)
  local item = {global = moduleName, name = name, handler = handler}
  bind(item, rawget(_G, moduleName))
  installed[#installed + 1] = item
  return item
end

local function route(moduleName, owner, names)
  for _, name in ipairs(names) do
    wrap(moduleName, name, function(_, ...) return owner[name](...) end)
  end
end

local function listen(name, handlers)
  local wrappers = {}
  for key, handler in pairs(handlers) do
    wrappers[key] = function(original, target)
      if type(original) ~= "function" then error("Missing listener API: " .. name .. "." .. key) end
      return function(...)
        if isActive() then return handler(original, target, ...) end
        return original(...)
      end
    end
  end
  local install, uninstall, refresh = patchRegistry.fieldSwap(function() return optional(name) end, wrappers)
  levelPatches[#levelPatches + 1] = {install = install, uninstall = uninstall, refresh = refresh}
end

local function routes(owner, names)
  local handlers = {}
  for _, name in ipairs(names) do
    handlers[name] = function(_, _, ...) return _G[owner][name](...) end
  end
  return handlers
end

local function validatePresenceDeclaration(declaration)
  if type(declaration.owner) ~= "string" or not declaration.owner:match("^[%w_]+$") then
    return "invalid owner"
  end
  if type(declaration.method) ~= "string" or not declaration.method:match("^[%a_][%w_]*$") then
    return "invalid activity predicate"
  end
  if not catalog.string(declaration.activity) then return "missing activity" end
  if not catalog.number(declaration.order) then return "missing priority order" end
end

-- Resolves rich presence activities from provider-owned declarations in their priority order.
-- The owner is resolved on each call so unloading or replacing a feature leaves no stale service reference.
function M.declaredPresenceActivity(fallback)
  local declarations = catalog.scan(PRESENCE_ACTIVITIES_DIR, validatePresenceDeclaration, "overhaul_presence")
  for _, declaration in ipairs(declarations) do
    local owner = optional(declaration.owner)
    if owner and owner[declaration.method]() then return declaration.activity end
  end
  return fallback
end

local function activity()
  if core_replay.getState() ~= "inactive" then return "replay" end
  if ui_pause_photomode and ui_pause_photomode.isPhotomodeSessionActive() then return "photo_mode" end
  return M.declaredPresenceActivity("career")
end

local function createLevelPatches()
  listen("gameplay_crawl_saveSystem", routes("overhaul_integration_services_crawlScores", {
    "savePlayerCrawlTrailScoresForTrailById", "getPlayerCrawlTrailById", "getPlayerCrawlTrailsById",
    "addNewPlayerScore", "resetPlayerTrailScores", "getPlayerTrailStats"
  }))
  listen("gameplay_drag_saveSystem", routes("overhaul_integration_services_dragScores", {
    "saveDialTimes", "getDialTimes", "getHistory", "getCurrentSavePath", "saveDialFile"
  }))
  listen("gameplay_drag_core", {
    getCurrentSavePath = function() return overhaul_integration_services_dragScores.getCurrentSavePath() end,
    isDragEnabled = function() return true end,
    -- Freeroam events award skill XP; a stock drag reward would count it twice.
    setCareerRewards = function() return {} end,
  })
end

local function install()
  local statistic = overhaul_integration_services_statistic
  for _, name in ipairs({"metricAdd", "metricSet", "timerStart", "timerStop", "forceTimerUpdate"}) do
    wrap("gameplay_statistic", name, function(original, ...)
      statistic[name](...)
      return original(...)
    end)
  end
  for _, name in ipairs({"metricGet", "metricGetMatchPattern", "callbackRegister", "callbackRemove"}) do
    wrap("gameplay_statistic", name, function(original, ...)
      local careerArgumentIndex = (name == "callbackRegister" or name == "callbackRemove") and 4 or 2
      local useCareerStatistics = select(careerArgumentIndex, ...)
      if useCareerStatistics then return statistic[name](...) end
      return original(...)
    end)
  end
  route("gameplay_garageMode", overhaul_integration_services_garageMode, {
    "start", "stop", "isActive", "zoom", "setCamera", "setObjectsAutohide", "isObjectsAutohide", "testVehicle",
    "setLighting", "getLighting", "setGarageMenuState", "getGarageMenuState", "setVehicleDirty",
    "vehicleByIdOrActive", "onGarageEnter"
  })
  local presenceItem
  local function wrapPresence()
    if not presenceItem then
      presenceItem = wrap("util_richPresence", "setActivity", function(original) return original(activity()) end)
    elseif presenceItem.binding.target ~= util_richPresence or not wrapperLifetime.intact(presenceItem.binding) then
      wrapperLifetime.retire(presenceItem.binding)
      bind(presenceItem, util_richPresence)
    end
  end
  wrapPresence()
  wrap("util_richPresence", "onSettingsChanged", function(original, ...)
    local function updated(...)
      wrapPresence()
      return ...
    end
    return updated(original(...))
  end)
  for _, patch in ipairs(levelPatches) do patch.install() end
end

-- Only a replaced module table is re-wrapped; settings changes re-wrap setActivity on the same table themselves.
local function refresh()
  for _, item in ipairs(installed) do
    local liveModule = rawget(_G, item.global)
    if liveModule and liveModule ~= item.binding.target then
      wrapperLifetime.retire(item.binding, false)
      bind(item, liveModule)
    end
  end
  for _, patch in ipairs(levelPatches) do patch.refresh() end
end

local function uninstall()
  for index = #levelPatches, 1, -1 do levelPatches[index].uninstall() end
  for index = #installed, 1, -1 do
    local item = installed[index]
    wrapperLifetime.retire(item.binding, false)
    if item.name:match("^on") then extensions.hookUpdate(item.name) end
  end
  installed = {}
  if util_richPresence and util_richPresence.onWorldReadyState then util_richPresence.onWorldReadyState() end
end

function M.onExtensionLoaded()
  if registered then return end
  patchRegistry = overhaul_shell_patches
  levelPatches = {}
  createLevelPatches()
  patchRegistry.register("overhaulListeners", install, uninstall, refresh)
  registered = true
  if isActive() then util_richPresence.setActivity(activity()) end
end

function M.onOverhaulBeforeCareerActivate()
  if gameplay_speedTrapLeaderboards and gameplay_speedTrapLeaderboards.saveLeaderboards then
    gameplay_speedTrapLeaderboards.saveLeaderboards()
  end
end

local function updatePresence()
  if isActive() and util_richPresence and util_richPresence.setActivity then util_richPresence.setActivity(activity()) end
end

function M.onOverhaulActive(enabled)
  if enabled then
    if gameplay_backgroundActivities_g2g then gameplay_backgroundActivities_g2g.deactivate() end
    if gameplay_forceField then
      restoreForceField = restoreForceField or gameplay_forceField.isActive()
      gameplay_forceField.deactivate()
    end
    updatePresence()
  elseif restoreForceField then
    restoreForceField = false
    if gameplay_forceField then gameplay_forceField.activate() end
  end
end

M.onOverhaulDeliveryModeStarted = updatePresence
M.onOverhaulDeliveryModeStopped = updatePresence
M.onOverhaulPartShoppingStarted = updatePresence
M.onOverhaulPartShoppingTransactionComplete = updatePresence
M.onOverhaulPartShoppingCancelled = updatePresence
function M.onExtensionUnloaded()
  if registered then
    patchRegistry.unregister("overhaulListeners")
    registered = false
  end
end

return M
