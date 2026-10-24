-- Owns Overhaul startup, scopes, input actions, vehicle extensions and teardown.
-- Reading order: roster and unload readiness, scopes, inputs, editor policy, mod identity, lifecycle and public hooks.
local M = {}

local modIdentity = require("overhaul/lib/platform/modIdentity")
local optional = require('overhaul/lib/platform/optional')
local capabilities = require('overhaul/lib/platform/capabilities')
local manifest = require("overhaul/lib/career/manifest")
local devScope = require("overhaul/lib/lifecycle/scopes/dev")
local vehicleRoles = require("common/overhaul/vehicleRoles")

-- Config ------------------------------------------------------------------------------------------

local SUPPORTED_GAME_MINOR_VERSION = 40
-- Earlier versions wrote the tester action into the user folder.
local LEGACY_TESTER_ACTIONS = "/lua/ge/extensions/core/input/actions/rls_tester_menu.json"
local devKey = "dc124d6fb1a6261f"

-- Swap in overhaulAi without leaving the vehicle stuck in default disabled mode.
local OVERRIDE_AI_CMD = [[
if not extensions.overhaulAi then extensions.load('overhaulAi') end
if overhaulAi and ai ~= overhaulAi then
  local prevMode = ai and ai.mode
  ai = overhaulAi
  if prevMode and prevMode ~= 'disabled' and ai.setMode then
    ai.setMode(prevMode)
  end
end
]]

-- State -------------------------------------------------------------------------------------------

-- Extensions Overhaul unloads with itself; setting a manual unload mode adds one (lib/career/manifest.lua).
local roster
local ownedExtensions = {}
local startedScopes = {}
local shuttingDown = false
-- Kept separate from cleanup readiness: a refused teardown still ends owner loading for this lifetime.
local ownerLoadingPermitted = false
local versionUnsupported = false
local testerHiddenThisSession = false
-- Path-named extensions are kept out of Lua reload snapshots (see blockUnreloadableExtensionNames).
local serializationBlocked = {}
-- A cleanup callback cannot start a second teardown while its result is still pending.
local preparingUnload = false
local triggerOwners = {map = nil, byName = {}}

-- Roster and scope loading ------------------------------------------------------------------------

local function getRoster()
  if not roster then
    roster = manifest.discoverShell()
    ownedExtensions = manifest.shellOwnedSeed(roster)
  end
  return roster
end

-- Stock unload hooks cannot veto removal; declared cleanup must finish before entering the loader.
local function prepareOwnerUnload(name, accepted, prepared, waiting)
  local declaration = accepted.byName[name]
  if not declaration or not declaration.beforeUnload then return true end
  if not extensions.isExtensionLoaded(name) then return true end
  local owner = optional(name)
  local method = owner and owner[declaration.beforeUnload]
  if type(method) ~= "function" then
    log("E", "extensionManager", "Loaded owner " .. name .. " is missing beforeUnload method " .. declaration.beforeUnload)
    return false
  end
  local ok, result = xpcall(method, debug.traceback)
  if not ok or result ~= true then
    if not waiting or not ok then
      log("E", "extensionManager", "Unload refused by " .. name .. "." .. declaration.beforeUnload .. ": " .. tostring(result))
    end
    return false
  end
  if roster ~= accepted or optional(name) ~= owner or not extensions.isExtensionLoaded(name) then
    log("E", "extensionManager", "Owner or roster changed while preparing unload: " .. name)
    return false
  end
  prepared[name] = owner
  return true
end

-- Stock unload also removes dependents; use its public loaded declarations without building another roster.
local function unloadCandidates(names, accepted)
  local selected = {}
  for _, name in ipairs(names or {}) do selected[name] = true end
  if not names then
    for name in pairs(accepted.owned) do selected[name] = true end
    for name in pairs(ownedExtensions) do selected[name] = true end
  end
  local changed = true
  local loaded = extensions.getLoadedExtensionsNames()
  while changed do
    changed = false
    for _, name in ipairs(loaded) do
      local owner = optional(name)
      for _, dependency in ipairs(owner and owner.dependencies or {}) do
        if selected[dependency] and not selected[name] then selected[name], changed = true, true end
      end
    end
  end
  local ordered = {}
  for name in pairs(selected) do ordered[#ordered + 1] = name end
  table.sort(ordered)
  return ordered
end

-- Readiness is checked afresh: an unchanged owner table may have acquired new resources since an earlier action.
-- Integrations may wait for pending work; suppress refusals while retaining diagnostics for errors.
local function prepareForUnload(names, waiting)
  if preparingUnload then
    log("E", "extensionManager", "Cannot reenter unload preparation")
    return false
  end
  local accepted = getRoster()
  local prepared = {}
  local ordered = unloadCandidates(names, accepted)
  preparingUnload = true
  local ok, ready = xpcall(function()
    for _, name in ipairs(ordered) do
      if not prepareOwnerUnload(name, accepted, prepared, waiting) then return false end
    end
    for _, name in ipairs(ordered) do
      local owner = prepared[name]
      if roster ~= accepted or owner and extensions.isExtensionLoaded(name) and optional(name) ~= owner then return false end
    end
    return true
  end, debug.traceback)
  preparingUnload = false
  if not ok then
    log("E", "extensionManager", "Unload preparation failed: " .. tostring(ready))
    return false
  end
  return ready
end

local function ownUnloadMode(name, mode)
  ownedExtensions[name] = true
  setExtensionUnloadMode(name, mode)
end

local function safeLoad(extName)
  local ok, err = xpcall(extensions.load, debug.traceback, extName)
  if not ok then
    log("E", "extensionManager", "Failed to load " .. tostring(extName) .. "; continuing startup:\n" .. tostring(err))
  end
  return ok
end

local integrations = require('overhaul/shell/extensionManager/integrations').new({
  exports = M, roster = getRoster, prepare = prepareForUnload,
  extensions = extensions, jobs = core_jobsystem, unloadMode = setExtensionUnloadMode,
  lookup = function(name) return rawget(_G, name) end,
  canLoad = function() return ownerLoadingPermitted and not shuttingDown and not preparingUnload end,
  load = function(name) ownUnloadMode(name, 'manual'); safeLoad(name) end,
})

-- Scope load modes: "each" loads one at a time, "grouped" sets every mode first, "modes" only sets them.
local function loadScope(id, names)
  local scope = manifest.shellScope(id, getRoster())
  names = names or scope
  startedScopes[id] = true
  if scope.load == "grouped" or scope.load == "modes" then
    for _, extName in ipairs(names) do ownUnloadMode(extName, "manual") end
    if scope.load == "modes" then return end
    for _, extName in ipairs(names) do safeLoad(extName) end
    return
  end
  for _, extName in ipairs(names) do
    ownUnloadMode(extName, "manual")
    safeLoad(extName)
  end
end

-- Stock career enters through freeroam_freeroam, so that core service stays loaded at the menu.
local function loadExtensions()
  loadScope("bootManual")
  -- Vanilla loads "manual" extensions right after modScripts run, before this deferred startup.
  loadManualUnloadExtensions()
end

-- Overhaul's career core stays loaded like vanilla career's; its modules load when a career starts.
local function loadCareerCore()
  loadScope("careerCore")
end

-- The editor's current hook dispatch does not include owners loaded inside it.
local function loadEditorScope(names)
  startedScopes.editor = true
  for _, name in ipairs(names or manifest.shellScope("editor", getRoster())) do
    if not extensions.isExtensionLoaded(name) then
      ownUnloadMode(name, "manual")
      if safeLoad(name) then
        local owner = optional(name)
        if owner and owner.onEditorInitialized then owner.onEditorInitialized() end
      end
    end
  end
end

-- Demand scopes load before their mode is set, so each owner exists before it is marked manual.
local function loadWorldScope(names, worldReady)
  startedScopes.world = true
  for _, name in ipairs(names or manifest.shellScope("world", getRoster())) do
    local wasLoaded = extensions.isExtensionLoaded(name)
    extensions.load(name)
    ownUnloadMode(name, "manual")
    -- A newly loaded owner is absent from the world-ready hook list already being dispatched.
    if worldReady and not wasLoaded then
      local declaration, owner = getRoster().byName[name], optional(name)
      local ready = declaration and declaration.reloadOnReady and owner and owner[declaration.reloadOnReady]
      if ready then ready() end
    end
  end
end

local function ensureFreeroamEventsLoaded(names)
  startedScopes.freeroamEvents = true
  for _, name in ipairs(names or manifest.shellScope("freeroamEvents", getRoster())) do
    if not extensions.isExtensionLoaded(name) then
      ownedExtensions[name] = true
      extensions.load(name)
    else
      local owner = roster.byName[name]
      local extension = optional(name)
      local reload = owner and owner.reloadOnReady and extension and extension[owner.reloadOnReady]
      if reload then reload() end
    end
  end
end

local function ensureCareerWorldLoaded(names)
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return
  end
  startedScopes.careerWorld = true
  for _, name in ipairs(names or manifest.shellScope("careerWorld", getRoster())) do
    ownUnloadMode(name, "manual")
    if not extensions.isExtensionLoaded(name) then extensions.load(name) end
  end
end

-- Facility declarations are the source of trigger names, including stations supplied by add-ons.
local function demandTriggerOwner(data)
  if not ownerLoadingPermitted or shuttingDown or preparingUnload then return end
  if not overhaul_career_career or not overhaul_career_career.isActive() then return end
  if data.event ~= "enter" or data.subjectID ~= be:getPlayerVehicleID(0) then return end
  local mapId = getCurrentLevelIdentifier()
  if not mapId or not overhaul_world_facilities then return end
  if triggerOwners.map ~= mapId then
    local byName = {}
    for _, declaration in pairs(getRoster().byName) do
      for _, facilityType in ipairs(declaration.triggerFacilityTypes or {}) do
        for _, facility in ipairs(overhaul_world_facilities.getFacilitiesByType(facilityType, mapId) or {}) do
          if type(facility.triggerName) == "string" then byName[facility.triggerName] = declaration end
        end
      end
    end
    triggerOwners = {map = mapId, byName = byName}
  end
  local declaration = triggerOwners.byName[data.triggerName]
  if not declaration or optional(declaration.id) then return end
  local owner = capabilities.get(declaration.capability)
  -- The new owner's trigger hook is absent from the dispatch that acquired it.
  if owner and owner.onBeamNGTrigger then owner.onBeamNGTrigger(data) end
end

-- Input actions -----------------------------------------------------------------------------------

-- Returns the specs that name at least one action missing from `actions`.
local function specsMissingActions(specs, actions)
  local missing = {}
  for _, spec in ipairs(specs) do
    for _, actionName in ipairs(spec.actions) do
      if not actions[actionName] then
        table.insert(missing, spec)
        break
      end
    end
  end
  return missing
end

-- Logs every action that is still unregistered; returns true only when none is left.
local function logUnregisteredActions(specs, actions)
  local allRegistered = true
  for _, spec in ipairs(specs) do
    for _, actionName in ipairs(spec.actions) do
      if not actions[actionName] then
        log("E", "extensionManager", "Failed to register input action: " .. actionName)
        allRegistered = false
      end
    end
  end
  return allRegistered
end

-- Bindings may have been parsed before their action existed and skipped as invalid; reread them now.
local function rereadBindings(specs)
  for _, spec in ipairs(specs) do core_input_bindings.onFileChanged(spec.path) end
end

-- BeamNG caches normal actions before unpacked mods finish mounting; reloading the action files adds them.
local function ensureInputActionsRegistered()
  local specs = getRoster().inputActions
  local actions = core_input_actions.getActiveActions() or {}
  local missingSpecs = specsMissingActions(specs, actions)
  if #missingSpecs == 0 then return true end

  for _, spec in ipairs(missingSpecs) do core_input_actions.onFileChanged(spec.path) end
  actions = core_input_actions.getActiveActions() or {}
  if not logUnregisteredActions(specs, actions) then return false end

  rereadBindings(missingSpecs)
  log("I", "extensionManager", "Registered mod input actions after mount")
  return true
end

-- Game version and BeamMP -------------------------------------------------------------------------

local function notifyOutdated()
  guihooks.trigger("toastrMsg", { type = "error", title = "Update required", msg = "RLS Career Overhaul is outdated. Please update to the latest version." })
end

local function checkVersion()
  local fileData = jsonReadFile("integrity.json")
  if type(fileData) == "table" and type(fileData.version) == "string" then
    local version = fileData.version
    local _, minor = version:match("^%s*(%d+)%.(%d+)")
    if tonumber(minor) ~= SUPPORTED_GAME_MINOR_VERSION then
      log("W", "extensionManager", "Unsupported game version " .. tostring(version) .. " (expected 0." .. SUPPORTED_GAME_MINOR_VERSION .. ".x)")
      notifyOutdated()
      return false
    end
  end
  return true
end

-- Overhaul does not run alongside BeamMP. The player's mods are left alone; career start refuses instead.
local function isBeamMPActive()
  local mods = core_modmanager.getMods() or {}
  local beammp = mods["multiplayerbeammp"]
  return beammp ~= nil and beammp.active ~= false
end

-- Returns true and tells the player why when Overhaul must not start.
local function refuseCareerStart()
  if versionUnsupported then
    notifyOutdated()
    return true
  end
  if not isBeamMPActive() then return false end
  log("W", "extensionManager", "BeamMP is active; Career Overhaul cannot start until it is disabled")
  guihooks.trigger("toastrMsg", { type = "warning", title = "Career Overhaul", msg = "Career Overhaul does not work while BeamMP is enabled. Disable BeamMP in the mod manager to play." })
  return true
end

-- Exclude path-named extensions from reload snapshots because stock deserialize cannot restore their names.
local function blockUnreloadableExtensionNames()
  local blocked
  for _, extName in ipairs(extensions.getLoadedExtensionsNames()) do
    if string.find(extName, "/", 1, true) and not serializationBlocked[extName] then
      serializationBlocked[extName] = true
      blocked = blocked or {}
      table.insert(blocked, extName)
    end
  end
  -- extensions.disableSerialization does not dedupe, hence serializationBlocked.
  if blocked then
    extensions.disableSerialization(blocked)
    log("I", "extensionManager", "Excluded path-named extensions from Lua reload serialization: " .. dumps(blocked))
  end
end

-- Own mod identity --------------------------------------------------------------------------------

local function deactivateSelf()
  ownerLoadingPermitted = false
  local mod = modIdentity.identifyOwnMod()
  if not mod then
    log("W", "extensionManager", "Could not find RLS Career Overhaul in the mod manager to deactivate it")
    return false
  end
  local ready = prepareForUnload()
  if not ready then return false end
  log("I", "extensionManager", "Deactivating RLS Career Overhaul")
  core_modmanager.deactivateMod(mod.modname)
  return true
end

-- Tester menu -------------------------------------------------------------------------------------

-- Drops the tester action from the input system; returns true when it was registered.
local function forgetTesterAction()
  local known = false
  pcall(function()
    local actions = core_input_actions.getActiveActions()
    if type(actions) == "table" then
      known = actions.rlsTesterMenuToggle ~= nil
      actions.rlsTesterMenuToggle = nil
    end
    for _, field in ipairs({ "uniqueActions", "normalActions", "activeActions", "actions" }) do
      local registry = core_input_actions[field]
      if type(registry) == "table" then registry.rlsTesterMenuToggle = nil end
    end
    if known then
      core_input_actions.onFileChanged(LEGACY_TESTER_ACTIONS, "deleted")
    end
  end)
  return known
end

-- Only the legacy user-folder file, and only when it holds nothing but the tester action, is removed.
local function removeTesterActionOverlay()
  local removed = false
  pcall(function()
    if not FS:fileExists(LEGACY_TESTER_ACTIONS) then return end
    local real = tostring(FS:getFileRealPath(LEGACY_TESTER_ACTIONS) or ""):gsub("\\", "/"):lower()
    if real == "" or real:find("/mods/", 1, true) or real:find("/temp/rls_career/", 1, true) then return end
    if real:find("/settings/inputmaps/overhaul/testerinput/", 1, true) then return end
    local def = jsonReadFile(LEGACY_TESTER_ACTIONS)
    if type(def) ~= "table" or next(def) ~= "rlsTesterMenuToggle" or next(def, "rlsTesterMenuToggle") ~= nil then return end
    removed = FS:removeFile(LEGACY_TESTER_ACTIONS) ~= false
  end)
  return removed
end

local function hideTesterFromPublicInput()
  if testerHiddenThisSession then return end
  testerHiddenThisSession = true
  local removed = removeTesterActionOverlay()
  if forgetTesterAction() or removed then
    -- Bindings to the tester action are skipped once the action is gone; the player's files stay as they are.
    pcall(function()
      core_input_bindings.onFileChanged(LEGACY_TESTER_ACTIONS)
      core_input_bindings.notifyUI("rls tester hide")
    end)
  end
end

local function loadTesterMenuIfKeyed()
  local names = manifest.shellScope("testerMenu", getRoster())
  if not devScope.isKeyValid(M.isDevKeyValid) then
    if not prepareForUnload(names) then return false end
    startedScopes.testerMenu = true
    for _, name in ipairs(names) do ownUnloadMode(name, "manual") end
    for _, name in ipairs(names) do extensions.unload(name) end
    hideTesterFromPublicInput()
    return
  end
  startedScopes.testerMenu = true
  for _, name in ipairs(names) do ownUnloadMode(name, "manual") end
  removeTesterActionOverlay()
  for _, name in ipairs(names) do
    extensions.load(name)
    local keyedExtension = _G[name]
    if keyedExtension and keyedExtension.ensureBound then keyedExtension.ensureBound() end
  end
end

-- Action filters ----------------------------------------------------------------------------------

-- Reload actions after unmount so bindings skip the absent actions while their saved bytes stay intact.
local function dropModInputActions()
  pcall(function()
    extensions.reload("core_input_actions")
  end)
end

-- Earlier versions wrote the tester action into the user folder; only that file, holding only that action, goes.

local function updateEditorBlocking()
  local blockedActions = { "editorToggle", "editorSafeModeToggle", "vehicleEditorToggle" }
  core_input_actionFilter.setGroup("RLS_DEACTIVATION", blockedActions)
  local cheatsEnabled = overhaul_career_economy_cheats and overhaul_career_economy_cheats.isCheatsMode()
  if not devScope.isKeyValid(M.isDevKeyValid) and overhaul_career_career.isActive() and not cheatsEnabled then
    core_input_actionFilter.addAction(0, "RLS_DEACTIVATION", true)
  else
    core_input_actionFilter.addAction(0, "RLS_DEACTIVATION", false)
  end
end

-- Vehicle extensions ------------------------------------------------------------------------------

local function queueOverrideAI(veh)
  if veh then
    veh:queueLuaCommand(OVERRIDE_AI_CMD)
  end
end

local function applyOverrideAI(vehId)
  local veh = vehId and be:getObjectByID(vehId)
  queueOverrideAI(veh)
end

local function applyCareerVehicleExtensions(veh)
  if not veh then return end
  local inventory = overhaul_career_garage_inventory
  local invId = inventory and inventory.getInventoryIdFromVehicleId(veh:getID())
  local vehicle = invId and inventory.getVehicle(invId)
  if not vehicleRoles.lookup({ inventoryVehicle = vehicle }).ownedFuelMultiplier then return end
  veh:queueLuaCommand("if not extensions.overhaulFuelMultiplier then extensions.load('overhaulFuelMultiplier') end")
end

local function getTrafficRoleName(vehId)
  if not gameplay_traffic or not gameplay_traffic.getTrafficData then return nil end
  local trafficData = gameplay_traffic.getTrafficData()[vehId]
  return trafficData and trafficData.role and trafficData.role.name or nil
end

-- Ownership does not require a second AI instance; autonomous roles request it explicitly.
local function onVehicleSpawned(vehId, veh)
  if not veh then return end

  if overhaul_career_garage_inventory and overhaul_career_garage_inventory.getInventoryIdFromVehicleId then
    local invId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
    if invId then
      applyCareerVehicleExtensions(veh)
      return
    end
  end

  local role = getTrafficRoleName(vehId)
  if vehicleRoles.lookup({ trafficRole = role }).spawnTrafficAI then
    queueOverrideAI(veh)
  end
end

-- Unloading ---------------------------------------------------------------------------------------

-- Reloading input actions and unloading overrides also unloads vanilla dependents, so their paths are kept to restore.
local function snapshotVanillaExtensions()
  local loadedBefore = {}
  for _, name in ipairs(extensions.getLoadedExtensionsNames()) do
    local extensionTable = optional(name)
    if type(extensionTable) == "table" and extensionTable.__extensionPath__ then
      loadedBefore[name] = extensionTable.__extensionPath__
    end
  end
  return loadedBefore
end

local function claimLoadedOwnedExtensions()
  for _, name in ipairs(extensions.getLoadedExtensionsNames()) do
    if manifest.unloadOwns(name, getRoster()) then ownedExtensions[name] = true end
  end
end

-- Owners may need the career modules during cleanup, so they go before the career stops.
local function unloadBeforeCareerStop()
  if not prepareForUnload(getRoster().beforeCareerStop) then return false end
  for _, name in ipairs(getRoster().beforeCareerStop) do
    if ownedExtensions[name] then extensions.unload(name) end
  end
end

local function unloadOwnedInOrder()
  local names = {}
  for name in pairs(ownedExtensions) do
    if name ~= "overhaul_shell_extensionManager" then names[#names + 1] = name end
  end
  table.sort(names)
  if not prepareForUnload(names) then return false end
  for _, name in ipairs(names) do extensions.unload(name) end
  extensions.unload("overhaul_shell_extensionManager")
end

-- Reloads the vanilla extensions that were unloaded alongside the overhaul; only vanilla files still exist now.
local function restoreVanillaExtensions(loadedBefore)
  local restore = {}
  local restoreBindings = false
  for name, extPath in pairs(loadedBefore) do
    if not optional(name) and not ownedExtensions[name]
        and FS:fileExists("/lua/ge/extensions/" .. extPath .. ".lua") then
      restore[#restore + 1] = name
      if name == "core_input_bindings" then restoreBindings = true end
    end
  end
  table.sort(restore)
  if #restore > 0 then
    extensions.load(restore)
    -- Restoring module code does not repeat the VM's first-frame device initialization.
    if restoreBindings then
      local bindings = optional("core_input_bindings")
      if bindings then bindings.onDeviceChanged() end
    end
    log("I", "extensionManager", "Restored vanilla extensions after unloading the overhaul: " .. table.concat(restore, ", "))
  end
end

-- jbeam only rebuilds its part lists when a scanned file is re-read; otherwise removed parts stay selectable.
local function refreshJbeamCommonParts()
  local commonParts = FS:findFiles("/vehicles/common/", "*.jbeam", -1, false, false)
  if commonParts and commonParts[1] then require("jbeam/io").onFileChanged(commonParts[1], "modified") end
end

-- Waits up to 60 seconds for the generated level to be left, then removes its files.
local function removeGeneratedLevelWhenLeft(removeGeneratedLevel, generatedLevels)
  return function(job)
    local waited = 0
    while generatedLevels[getCurrentLevelIdentifier()] and waited < 60 do
      job.sleep(0.5)
      waited = waited + 0.5
    end
    if generatedLevels[getCurrentLevelIdentifier()] then
      log("W", "extensionManager", "Kept generated level cache: the level is still loaded after unload timeout")
      return
    end
    removeGeneratedLevel()
  end
end

-- A level loaded with the overhaul's overrides cannot keep running on the vanilla ones.
local function returnToMenuAfterUnload(removeGeneratedLevel, generatedLevels)
  if getCurrentLevelIdentifier() then
    log("I", "extensionManager", "Returning to the main menu after unloading the overhaul")
    returnToMainMenu()
    -- The mod manager reloads the UI next, which loses the loading screen; continue as the UI does then.
    if core_gamestate.loading() then core_gamestate.loadingScreenActive() end
    if removeGeneratedLevel then
      core_jobsystem.create(removeGeneratedLevelWhenLeft(removeGeneratedLevel, generatedLevels))
    end
  elseif removeGeneratedLevel then
    removeGeneratedLevel()
  end
end

local function finishUnloadAllExtensions()
  shuttingDown = true
  if overhaul_shell_gameMode and overhaul_shell_gameMode.stop then overhaul_shell_gameMode.stop() end
  local loadedBefore = snapshotVanillaExtensions()
  dropModInputActions()
  claimLoadedOwnedExtensions()
  for name in pairs(ownedExtensions) do setExtensionUnloadMode(name, "auto") end
  local levelProxy = overhaul_world_levelProxy
  local removeGeneratedLevel = levelProxy and levelProxy.removeGenerated
  local generatedLevels = levelProxy and levelProxy.getGeneratedLevels() or {}
  if unloadBeforeCareerStop() == false then return false end
  if overhaul_career_career and overhaul_career_career.deactivateCareer then overhaul_career_career.deactivateCareer(false) end
  if unloadOwnedInOrder() == false then return false end
  -- The mod is already unmounted here, so only vanilla extension files still exist.
  restoreVanillaExtensions(loadedBefore)
  refreshJbeamCommonParts()
  returnToMenuAfterUnload(removeGeneratedLevel, generatedLevels)
end

local function unloadAllExtensions()
  ownerLoadingPermitted = false
  if shuttingDown then return end
  local ready = prepareForUnload()
  if not ready then return false end
  if finishUnloadAllExtensions() == false then shuttingDown = false; return false end
end

-- Startup -----------------------------------------------------------------------------------------

-- Runs the version check a few seconds after startup rather than during it.
local function checkVersionLater()
  core_jobsystem.create(function(job)
    job.sleep(5)
    if not checkVersion() then
      versionUnsupported = true
      deactivateSelf()
    end
  end)
end

local function startup()
  ownerLoadingPermitted = false
  shuttingDown = false
  getRoster()
  modIdentity.identifyOwnMod()
  blockUnreloadableExtensionNames()
  refuseCareerStart()
  loadCareerCore()
  ensureInputActionsRegistered()
  loadTesterMenuIfKeyed()

  -- Stop the boot-time career shell before overrides reload to avoid rebuilding a graph that the menu immediately unloads.
  if not core_gamestate.state or core_gamestate.state.state ~= "overhaul" then
    loadExtensions()
  end

  -- Register the Lua-authoritative routes before the UI reload, so restored routes resolve on first mount.
  loadScope("routes")
  loadScope("shell")
  loadScope("services")
  loadScope("vehicleTools")

  -- The UI loaded before this deferred startup; reload it so the mod's routes and mounts are seen.
  reloadUI()

  loadScope("guards")
  loadScope("settings")
  loadScope("late")
  checkVersionLater()
  ownerLoadingPermitted = not shuttingDown
  integrations.refresh()
  if editor and editor.initialized then loadEditorScope() end
end

-- Roster refresh ----------------------------------------------------------------------------------

local function resetDeliveryTemplates()
  local templates = package.loaded["overhaul/lib/logistics/templates"]
  if templates and templates.reset then templates.reset() end
end

-- Owners that vanished from the mounted mods are unloaded before the roster is replaced.
local function unloadRemovedOwners(previous, nextRoster)
  local removed, preparation = {}, {}
  for name in pairs(previous.declared) do
    if not nextRoster.declared[name] and (ownedExtensions[name] or previous.owned[name]) then
      removed[#removed + 1] = name
      preparation[#preparation + 1] = name
    elseif previous.byName[name] and previous.byName[name].beforeUnload
        and (not nextRoster.byName[name] or nextRoster.byName[name].beforeUnload ~= previous.byName[name].beforeUnload) then
      preparation[#preparation + 1] = name
    end
  end
  table.sort(removed)
  if not prepareForUnload(preparation) then return false end
  for _, name in ipairs(removed) do
    if ownedExtensions[name] or extensions.isExtensionLoaded(name) then
      setExtensionUnloadMode(name, "auto")
      extensions.unload(name)
    end
    ownedExtensions[name] = nil
  end
  return true
end

-- Loads the members a started scope gained in this rescan; the members it already had stay as they are.
local function loadScopeAdditions(previous, scope)
  local counts, added = {}, {}
  for _, name in ipairs(previous.byId[scope.id]) do counts[name] = (counts[name] or 0) + 1 end
  for _, name in ipairs(scope) do
    if (counts[name] or 0) > 0 then counts[name] = counts[name] - 1 else added[#added + 1] = name end
  end
  if #added == 0 then return end
  if scope.id == "world" then
    loadWorldScope(added, getCurrentLevelIdentifier() ~= nil)
  elseif scope.id == "freeroamEvents" then
    ensureFreeroamEventsLoaded(added)
  elseif scope.id == "careerWorld" then
    ensureCareerWorldLoaded(added)
  elseif scope.id == "testerMenu" then
    loadTesterMenuIfKeyed()
  elseif scope.id == "editor" then
    loadEditorScope(added)
  elseif scope.load ~= "demand" and scope.load ~= "parent" then
    loadScope(scope.id, added)
    if scope.load == "modes" then loadManualUnloadExtensions() end
  end
end

-- Retain the accepted roster until removed owners unload; unmount may expose a base declaration underneath.
local function refreshRoster()
  if preparingUnload then return false end
  local previous = getRoster()
  local nextRoster = manifest.discoverShell()
  if not unloadRemovedOwners(previous, nextRoster) then return false end
  roster = nextRoster
  integrations.refresh()
  triggerOwners = {map = nil, byName = {}}
  for name in pairs(manifest.shellOwnedSeed(roster)) do ownedExtensions[name] = true end
  for _, scope in ipairs(roster.scopes) do
    if startedScopes[scope.id] then loadScopeAdditions(previous, scope) end
  end
  ensureInputActionsRegistered()
end

local function onModActivated(modData)
  require("overhaul/lib/platform/manifests").invalidate()
  capabilities.reset()
  resetDeliveryTemplates()
  -- Stock sends this after mounting and starting the mod, including when a refused cleanup retained this manager.
  if modIdentity.isOwnMod(modData) and modData.active == true and roster and startedScopes.shell then
    shuttingDown = false
    ownerLoadingPermitted = true
  end
  if not shuttingDown then refreshRoster() end
end

local function onModDeactivated(modData)
  require("overhaul/lib/platform/manifests").invalidate()
  capabilities.reset()
  resetDeliveryTemplates()
  if not modData or not modData.modname then return end
  if modData.modname:find("BatchActivation_") or modData.modname:find("BatchDeactivation_") then return end
  if modIdentity.isOwnMod(modData) then
    unloadAllExtensions()
  elseif not shuttingDown then
    refreshRoster()
  end
end

-- Public API: startup and identity ----------------------------------------------------------------

M.isBeamMPActive = isBeamMPActive
M.refuseCareerStart = refuseCareerStart
M.identifyOwnMod = modIdentity.identifyOwnMod
function M.childrenOf(parentId)
  return manifest.childrenOf(parentId, getRoster())
end

M.deactivateSelf = deactivateSelf
M.prepareForUnload = prepareForUnload
M.canLoadOwners = function()
  return ownerLoadingPermitted and not shuttingDown and not preparingUnload
end
M.ensureInputActionsRegistered = ensureInputActionsRegistered

M.isDevKeyValid = function()
  return devKey == FS:hashFile("devkey.txt")
end

M.getModData = modIdentity.getModData
M.acquireRouteOwner = function(_, toRoute)
  if not M.canLoadOwners() then return false end
  for _, declaration in pairs(getRoster().byName) do
    for _, route in ipairs(declaration.demandRoutes or {}) do
      if route == toRoute.name then return capabilities.get(declaration.capability) ~= nil end
    end
  end
  return false
end

-- Public API: vehicle extensions and tutorial -----------------------------------------------------

M.applyOverrideAI = applyOverrideAI
M.applyCareerVehicleExtensions = applyCareerVehicleExtensions

M.replayPhoneTutorial = function()
  if overhaul_career_career and overhaul_career_career.isActive() then
    local tutorial = capabilities.get('phoneTutorial')
    if tutorial and tutorial.forceStartPhoneTutorial then
      tutorial.forceStartPhoneTutorial()
      return true
    end
  end

  guihooks.trigger("toastrMsg", {
    type = "info",
    title = "Phone tutorial",
    msg = "Start or resume a career before replaying the phone tutorial.",
  })
  return false
end

-- Game hooks --------------------------------------------------------------------------------------

M.onExtensionLoaded = startup
M.onEditorInitialized = function()
  if not M.canLoadOwners() then return end
  loadEditorScope()
end
-- Timed editor initialization calls only stock editor-folder owners directly.
M.onEditorActivated = M.onEditorInitialized
M.onExtensionUnloaded = function()
  integrations.stop()
  ownerLoadingPermitted = false
  capabilities.reset()
end
M.onWorldReadyState = function(worldReadyState)
  if shuttingDown then return end
  if worldReadyState == 2 then
    loadWorldScope(nil, true)
    updateEditorBlocking()
    ensureFreeroamEventsLoaded()
    ensureCareerWorldLoaded()
    blockUnreloadableExtensionNames()
    loadTesterMenuIfKeyed()
  end
end

M.onCareerActivated = function()
  if shuttingDown then return end
  ensureFreeroamEventsLoaded()
  ensureCareerWorldLoaded()
  blockUnreloadableExtensionNames()
  loadTesterMenuIfKeyed()
end

M.onOverhaulActive = function(active)
  if shuttingDown then return end
  if not active then loadWorldScope() end
end

-- Restore play navigation after stock UI initialization, which only knows the freeroam title screen.
M.onAllUiReady = function()
  if shuttingDown or not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  core_jobsystem.create(function(job)
    job.sleep(0.1)
    if overhaul_career_career and overhaul_career_career.isActive() and ui_router and ui_router.navigate then ui_router.navigate("play") end
  end)
end

M.onOverhaulCheatsModeChanged = function()
  updateEditorBlocking()
end

M.onVehicleSpawned = onVehicleSpawned
M.onBeamNGTrigger = demandTriggerOwner
M.onModActivated = onModActivated
M.onModDeactivated = onModDeactivated
M.onModManagerReady = resetDeliveryTemplates
M.onClientEndMission = function()
  triggerOwners = {map = nil, byName = {}}
  resetDeliveryTemplates()
end
M.onFileChanged = function(filename)
  if type(filename) == "string" and filename:match("%.delivery%w+%.json$") then resetDeliveryTemplates() end
end

return M
