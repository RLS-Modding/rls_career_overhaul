-- Installs reversible stock patches while Overhaul runs, with persistent profile isolation.
-- Reading order: registry lifetime, field swaps, refresh, diagnostics, stock adapters and game hooks.
local M = {}

local isOverhaulActive = require("overhaul/lib/career/context").isOverhaulActiveSafe
local optional = require('overhaul/lib/platform/optional')
local wrapperLifetime = require("overhaul/lib/shell/wrapperLifetime")

-- Config ------------------------------------------------------------------------------------------

local REFRESH_INTERVAL = 2
local OUTRANKS_CAREER = {multiplayer = true, mission = true, scenario = true, garage = true}
local ACTIVITY_ACCEPT_EVENT = "OverhaulActivityAcceptUpdate"

-- State -------------------------------------------------------------------------------------------

local patches = {}
local patchesById = {}
local enabled = false
local persistentPatches = {}
local persistentById = {}
local onDemand = {}
local refreshTimer = 0
local playmodeStates

-- Registry lifetime -------------------------------------------------------------------------------

local function hasEnabledPatch()
  for _, patch in ipairs(patches) do
    if patch.enabled then return true end
  end
  return false
end

local function disablePatch(patch)
  local ok, err = pcall(patch.uninstall)
  if ok then
    patch.enabled = false
    return true
  end
  patch.lastError = "uninstall: " .. tostring(err)
  return false, tostring(err)
end

local function appendError(errors, id, err)
  errors[#errors + 1] = id .. ": " .. err
end

function M.register(id, install, uninstall, refresh)
  if type(id) ~= "string" or id == "" then error("patch id must be a non-empty string", 2) end
  if type(install) ~= "function" then error("patch install must be a function", 2) end
  if type(uninstall) ~= "function" then error("patch uninstall must be a function", 2) end
  if refresh ~= nil and type(refresh) ~= "function" then error("patch refresh must be a function", 2) end
  if patchesById[id] then error("patch already registered: " .. id, 2) end

  local patch = {id = id, install = install, uninstall = uninstall, refresh = refresh, enabled = false}
  patches[#patches + 1] = patch
  patchesById[id] = patch

  if enabled then
    patch.enabled = true
    local ok, err = pcall(patch.install)
    if not ok then
      patch.lastError = "install: " .. tostring(err)
      local cleaned, cleanupErr = disablePatch(patch)
      local message = "Failed to enable patch '" .. id .. "': " .. tostring(err)
      if not cleaned then message = message .. " (cleanup failed: " .. cleanupErr .. ")" end
      error(message, 0)
    end
    patch.installs = (patch.installs or 0) + 1
  end

  return true
end

function M.enableAll()
  local wasEnabled = enabled
  enabled = true

  local activated = {}
  for _, patch in ipairs(patches) do
    if not patch.enabled then
      patch.enabled = true
      local ok, err = pcall(patch.install)
      if ok then
        patch.installs = (patch.installs or 0) + 1
        activated[#activated + 1] = patch
      else
        patch.lastError = "install: " .. tostring(err)
        local rollbackErrors = {}
        local cleaned, cleanupErr = disablePatch(patch)
        if not cleaned then appendError(rollbackErrors, patch.id, cleanupErr) end

        for index = #activated, 1, -1 do
          local activePatch = activated[index]
          local rollbackOk, rollbackErr = disablePatch(activePatch)
          if not rollbackOk then appendError(rollbackErrors, activePatch.id, rollbackErr) end
        end

        enabled = wasEnabled or hasEnabledPatch()
        local message = "Failed to enable patch '" .. patch.id .. "': " .. tostring(err)
        if #rollbackErrors > 0 then
          message = message .. " (rollback failed: " .. table.concat(rollbackErrors, "; ") .. ")"
        end
        error(message, 0)
      end
    end
  end

  return true
end

function M.disableAll()
  local errors = {}
  for index = #patches, 1, -1 do
    local patch = patches[index]
    if patch.enabled then
      local ok, err = disablePatch(patch)
      if not ok then appendError(errors, patch.id, err) end
    end
  end

  enabled = hasEnabledPatch()
  if #errors > 0 then error("Failed to disable patches: " .. table.concat(errors, "; "), 0) end
  return true
end

function M.unregister(id)
  local patch = patchesById[id]
  if not patch then return false end
  if patch.enabled then
    local ok, err = disablePatch(patch)
    if not ok then error("Failed to disable patch '" .. id .. "': " .. err, 0) end
  end
  patchesById[id] = nil
  for index, registered in ipairs(patches) do
    if registered == patch then table.remove(patches, index) break end
  end
  return true
end

-- Field swaps -------------------------------------------------------------------------------------

-- Self-guarded hot paths return true as their second result to avoid an extra call.
function M.fieldSwap(resolve, wrappers)
  if type(resolve) ~= "function" then error("patch resolve must be a function", 2) end
  if type(wrappers) ~= "table" then error("patch wrappers must be a table", 2) end
  return wrapperLifetime.create(resolve, wrappers, extensions.hookUpdate)
end

function M.loadedExtension(name)
  return function()
    if optional(name) == nil then extensions.load(name) end
    return optional(name)
  end
end

-- Waiting for the router preserves stock on-demand loading.
function M.onDemandExtension(name)
  if onDemand[name] == nil then onDemand[name] = false end
  return function() return optional(name) end
end

function M.registerFields(id, resolve, wrappers)
  local install, uninstall, refresh = M.fieldSwap(resolve, wrappers)
  return M.register(id, install, uninstall, refresh)
end

function M.fieldSwaps(specs)
  local parts = {}
  for index, spec in ipairs(specs) do parts[index] = {M.fieldSwap(spec[1], spec[2])} end
  local function install() for _, part in ipairs(parts) do part[1]() end end
  local function uninstall() for index = #parts, 1, -1 do parts[index][2]() end end
  local function refresh() for _, part in ipairs(parts) do part[3]() end end
  return install, uninstall, refresh
end

-- Refresh -----------------------------------------------------------------------------------------

local function refreshPatch(patch)
  if not patch.enabled or not patch.refresh then return false end
  local ok, err = pcall(patch.refresh)
  if not ok then patch.lastError = "refresh: " .. tostring(err) end
  if not ok then log("E", "overhaul_shell_patches", "Refreshing patch '" .. patch.id .. "' failed: " .. tostring(err)) end
  return ok
end

local function refreshEnabled()
  for _, patch in ipairs(patches) do refreshPatch(patch) end
end

-- Owner-approved profile isolation stays installed outside Overhaul too.

function M.registerPersistent(id, install, uninstall, refresh)
  if type(id) ~= "string" or id == "" then error("patch id must be a non-empty string", 2) end
  if type(install) ~= "function" or type(uninstall) ~= "function" then error("patch install/uninstall must be functions", 2) end
  if persistentById[id] or patchesById[id] then error("patch already registered: " .. id, 2) end
  local patch = {id = id, install = install, uninstall = uninstall, refresh = refresh, enabled = true}
  persistentPatches[#persistentPatches + 1] = patch
  persistentById[id] = patch
  local ok, err = pcall(install)
  if ok then
    patch.installs = 1
  else
    patch.lastError = "install: " .. tostring(err)
    disablePatch(patch)
    log("E", "overhaul_shell_patches", "Installing persistent patch '" .. id .. "' failed: " .. tostring(err))
  end
  return ok
end

function M.registerPersistentFields(id, resolve, wrappers)
  local install, uninstall, refresh = M.fieldSwap(resolve, wrappers)
  return M.registerPersistent(id, install, uninstall, refresh)
end

local function refreshPersistent()
  for _, patch in ipairs(persistentPatches) do refreshPatch(patch) end
end

local function uninstallPersistent()
  for index = #persistentPatches, 1, -1 do
    local patch = persistentPatches[index]
    if patch.enabled then disablePatch(patch) end
  end
end

function M.persistent()
  local result = {}
  for _, patch in ipairs(persistentPatches) do
    if patch.enabled then result[#result + 1] = patch.id end
  end
  return result
end

-- Level loads can replace game modules; refresh Overhaul's patches, then the persistent ones.
local function refreshForLevel()
  refreshEnabled()
  refreshPersistent()
end

local function refreshOnDemand()
  local loaded = false
  for name, seen in pairs(onDemand) do
    local module = optional(name)
    if module ~= nil and module ~= seen then
      onDemand[name] = module
      loaded = true
    end
  end
  if loaded and enabled then refreshEnabled() end
  return loaded
end
M.refreshOnDemand = refreshOnDemand

function M.refresh(id)
  local patch = patchesById[id]
  return patch ~= nil and refreshPatch(patch)
end
M.refreshAll = refreshEnabled

-- Periodic refresh catches stock modules loaded after Overhaul starts.
local function onUpdate(dtReal)
  if not enabled then return end
  refreshTimer = refreshTimer + (dtReal or 0)
  if refreshTimer < REFRESH_INTERVAL then return end
  refreshTimer = 0
  refreshEnabled()
end

-- Diagnostics -------------------------------------------------------------------------------------

function M.list()
  local result = {}
  for _, patch in ipairs(patches) do
    result[#result + 1] = {id = patch.id, enabled = patch.enabled}
  end
  return result
end

function M.active()
  local result = {}
  for _, patch in ipairs(patches) do
    if patch.enabled then result[#result + 1] = patch.id end
  end
  return result
end

function M.diagnostics()
  local result = {running = enabled, registered = #patches, active = #M.active(), patches = {}}
  for _, patch in ipairs(patches) do
    result.patches[#result.patches + 1] = {id = patch.id, enabled = patch.enabled, installs = patch.installs or 0,
      lastError = patch.lastError}
  end
  result.persistent = {}
  for _, patch in ipairs(persistentPatches) do
    result.persistent[#result.persistent + 1] = {id = patch.id, enabled = patch.enabled, installs = patch.installs or 0,
      lastError = patch.lastError}
  end
  return result
end

-- Stock adapters ----------------------------------------------------------------------------------

-- Modes that outrank career keep their own pause menus.

local function wrapContext(context, ...)
  if isOverhaulActive() and type(context) == "table" and not OUTRANKS_CAREER[context.mode] then
    context.mode = "overhaul"
  end
  return context, ...
end

-- The service is a required module; a Lua reload replaces it and refresh wraps the new one.
M.registerFields("navigationContext", function() return require('ge/extensions/ui/router/services/navigationContext') end, {
  getContext = function(original)
    if type(original) ~= "function" then error("navigation context service has no getContext function") end
    return function(...) return wrapContext(original(...)) end
  end,
})

-- Patch a newly loaded provider before the router calls its hook.
M.registerFields("onDemandModules", function()
  return require('ge/extensions/ui/router/utils')
end, {
  resolveFunctionReference = function(original)
    return function(...)
      local fn, err, hard = original(...)
      if fn and refreshOnDemand() then fn, err, hard = original(...) end
      return fn, err, hard
    end
  end,
})

-- Stock marker visibility uses this shared set of playmode states.

local function uninstallPlaymodeStatePatch()
  if playmodeStates and playmodeStates.overhaul == true then playmodeStates.overhaul = nil end
  playmodeStates = nil
end

local function installPlaymodeStatePatch()
  local markers = gameplay_playmodeMarkers
  local states = type(markers) == "table" and markers.validPlaymodeMarkersStates
  if playmodeStates == states then return end
  uninstallPlaymodeStatePatch()
  if type(states) ~= "table" or states.overhaul ~= nil then return end
  states.overhaul = true
  playmodeStates = states
end

M.register("playmodeMarkerStates", installPlaymodeStatePatch, uninstallPlaymodeStatePatch, installPlaymodeStatePatch)

local pauseHome = require("overhaul/shell/patches/pauseHome")

local function pauseLifecycle(includeContent)
  return function(original)
    return function(context, toRoute, fromRoute, data, ...)
      local result = {original(context, toRoute, fromRoute, data, ...)}
      local ok, err = pcall(pauseHome.adjustLayout, context, toRoute, data, includeContent)
      if not ok then log("E", "overhaul.patches", "pause layout: " .. tostring(err)) end
      return unpack(result)
    end
  end
end

-- Pause Home, System and tabs as in career, built on Overhaul's modules.
M.registerFields("pauseLayout", M.onDemandExtension("ui_pause_routeLifecycleCallbacks"), {
  onPauseEnter = pauseLifecycle(false),
  onPauseMount = pauseLifecycle(true),
})

-- The stock pause profile card reads vanilla career's current profile.
M.registerFields("pauseProfileOverview", M.loadedExtension("career_career"), {
  sendCurrentProfileData = function(original, career)
    return function(...) return pauseHome.currentProfileData(career, original, ...) end
  end,
})

-- ui_missionInfo.openActivityAcceptDialogue for Overhaul: same bookkeeping and hooks, but the prompt
-- goes to Overhaul's own activity prompt instead of the stock one.
local function openActivityPrompt(missionInfo, content)
  content = content or {}
  missionInfo.buttonsTable = {}
  missionInfo.elemDataTable = {}
  for index, element in ipairs(content) do
    missionInfo.buttonsTable[index] = element.buttonFun
    element.missionInfoPerformActionIndex = index
    missionInfo.elemDataTable[index] = element.data
  end
  extensions.hook("onActivityAcceptUpdate", content)
  guihooks.trigger(ACTIVITY_ACCEPT_EVENT, content)

  local oldState = missionInfo.openState
  missionInfo.openState = "opened"
  extensions.hook("onMissionInfoChangedState", oldState, missionInfo.openState, content)
end

-- Marker prompts go to Overhaul's own activity prompt.
M.registerFields("activityPrompt", M.loadedExtension("ui_missionInfo"), {
  openActivityAcceptDialogue = function(original, missionInfo)
    local ownsPrompt = false
    return function(content, ...)
      if not isOverhaulActive() then
        ownsPrompt = false
        return original(content, ...)
      end
      -- A stock prompt can still be open when the mode changes. Close it through
      -- its owner to reset both the 0.40.1 input filter and its binding-change
      -- flag. Overhaul's prompt policy then reserves only competing vehicle
      -- bindings, leaving phone, walk and horn independently usable.
      if not ownsPrompt and missionInfo.openState == "opened" then missionInfo.closeDialogue() end
      ownsPrompt = true
      return openActivityPrompt(missionInfo, content)
    end
  end,
})

-- Keep RLS-era or unreadable saves out of vanilla career, which cannot safely load them.
local function gameReader()
  return {
    list = function(dir) return FS:directoryList(dir, false, true) or {} end,
    isDir = function(dir) return FS:directoryExists(dir) end,
    json = function(file) return jsonReadFile(file) end,
  }
end

-- Returns true and the reason when one folder's info.json would break stock career code.
local function infoProblem(info)
  if type(info) ~= "table" then return "info" end
  if info.version ~= nil and type(info.version) ~= "number" then return "version" end
  if type(info.date) ~= "string" then return "date" end
  return nil
end

-- profileDir: "<save root><profile>" without a trailing slash. Returns hidden, reason.
local function stockProfileCheck(profileDir, reader, specificSaveFolder)
  reader = reader or gameReader()
  if not reader.isDir(profileDir) then return false end
  if specificSaveFolder and reader.isDir(profileDir .. '/' .. specificSaveFolder .. '/career/rls_career') then return true, "rls" end
  local newestDate, newestIsRls, hasRls = '0', false, false
  for _, entry in ipairs(reader.list(profileDir)) do
    local rls = reader.isDir(entry .. "/career/rls_career")
    hasRls = hasRls or rls
    local info = reader.json(entry .. "/info.json")
    if info ~= nil then
      local problem = infoProblem(info)
      if problem then return true, rls and "rls" or problem end
      -- Same pick as stock pickSaveByDate(folders, false).
      if info.date > newestDate and not info.corrupted then newestDate, newestIsRls = info.date, rls end
    end
  end
  -- A stale RLS autosave must not hide a newer stock career in the same profile.
  if newestIsRls or (newestDate == '0' and hasRls) then return true, "rls" end
  if newestDate == '0' then return true, "noSave" end
  return false
end

-- root: the stock save root with its trailing slash. Returns the kept names (stock order) and the hidden ones.
local function filterStockProfiles(root, profiles, reader)
  reader = reader or gameReader()
  local kept, hidden = {}, {}
  for _, name in ipairs(profiles) do
    if stockProfileCheck(root .. name, reader) then hidden[#hidden + 1] = name else kept[#kept + 1] = name end
  end
  return kept, hidden
end

local function stockSaveRoot(saveSystem)
  local ok, root = pcall(saveSystem.getSaveRootDirectory)
  return ok and type(root) == "string" and root or "settings/cloud/saves/"
end

-- career_saveSystem is a game startup extension; it is not loaded here (refreshForLevel installs it later).
M.registerPersistentFields("vanillaProfileFilter", function() return rawget(_G, "career_saveSystem") end, {
  getAllProfiles = function(original, saveSystem)
    return function(...)
      local profiles = original(...)
      if type(profiles) ~= "table" then return profiles end
      local ok, kept, hidden = pcall(filterStockProfiles, stockSaveRoot(saveSystem), profiles)
      if not ok then
        log("E", "overhaul_shell_patches", "vanilla profile filter failed, listing every profile: " .. tostring(kept))
        return profiles
      end
      if #hidden > 0 then
        log("D", "overhaul_shell_patches", "Hidden from vanilla career (RLS-era or unreadable saves): " .. table.concat(hidden, ", "))
      end
      return kept
    end
  end,
  setProfile = function(original, saveSystem)
    return function(profile, specificSaveFolder, ...)
      if type(profile) == "string" then
        local ok, hide = pcall(stockProfileCheck, stockSaveRoot(saveSystem) .. profile, nil, specificSaveFolder)
        if ok and hide then
          log("W", "overhaul_shell_patches", "Vanilla career will not load '" .. profile .. "': RLS-era or unreadable save (import it in Overhaul)")
          return false
        end
      end
      return original(profile, specificSaveFolder, ...)
    end
  end,
})

-- Game hooks --------------------------------------------------------------------------------------

M.onUpdate = onUpdate
M.onClientPreStartMission = refreshForLevel
M.onClientPostStartMission = refreshForLevel
M.onWorldReadyState = refreshForLevel

function M.onExtensionUnloaded()
  local ok, err = pcall(M.disableAll)
  uninstallPersistent()
  if not ok then error(err, 0) end
  return true
end

return M
