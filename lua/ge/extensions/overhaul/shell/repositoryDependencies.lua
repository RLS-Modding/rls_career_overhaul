-- Checks that required Repository mods are installed and active, and asks the player once when they are not.
-- Repository lookup stays optional until the mod manager is ready.
local M = {}

local dependencies = {{repoId = "M3KGZF2SN", modName = "yb_pro_pull_sled", title = "Youngblood Pro Pulling Sled Trailer"}}

local runtimeState = {prompted = {}}
local retryElapsed, totalWait = 0, 0
local waitingForServices = false

local function defaultServices()
  return {
    modManager = rawget(_G, "core_modmanager"),
    prompt = function(dependency, installed)
      local hooks = rawget(_G, "guihooks")
      if not hooks or not hooks.trigger then return false end
      local action = installed and "Enable it in Mod Manager" or "Install it from the in-game Repository"
      hooks.trigger("OpenTutorialPopup", {popups = {{
        id = "rlsDependency_" .. dependency.repoId,
        type = "info", isPopup = true, title = "Required mod unavailable",
        text = dependency.title .. " is " .. (installed and "disabled. " or "missing. ") .. action ..
          " to use sled pulling. Repository ID: " .. dependency.repoId .. ". Your mod settings have not been changed."
      }}})
      return true
    end,
  }
end

-- Returns the mod list, or a retry result when the mod manager cannot answer yet.
local function listInstalledMods(manager)
  if type(manager) ~= "table" or type(manager.getMods) ~= "function" then
    return nil, {ready = false, retry = true, reason = "modManagerUnavailable"}
  end
  if type(manager.isReady) == "function" then
    local ok, ready = pcall(manager.isReady)
    if not ok or ready == false then return nil, {ready = false, retry = true, reason = "modManagerNotReady"} end
  end
  local ok, mods = pcall(manager.getMods)
  if not ok or type(mods) ~= "table" then return nil, {ready = false, retry = true, reason = "modListUnavailable"} end
  return mods
end

-- Finds the dependency by folder name or Repository id; returns the folder name and the mod.
local function findInstalledMod(mods, dependency)
  for name, mod in pairs(mods) do
    if type(mod) == "table" then
      local data = type(mod.modData) == "table" and mod.modData or {}
      local repoId = mod.modID or mod.tagid or data.tagid or data.modID
      if name == dependency.modName or string.upper(tostring(repoId)) == string.upper(dependency.repoId) then
        return name, mod
      end
    end
  end
  return nil, nil
end

local function isModActive(installed)
  if not installed then return false end
  local active = installed.active
  if active == nil and type(installed.modData) == "table" then active = installed.modData.active end
  return active == true
end

-- Asks once per dependency; a failed prompt is retried on the next check.
local function promptOnce(dependency, services, state, installedName, installed)
  if state.prompted[dependency.repoId] then return {ready = false, retry = false, action = "prompted"} end
  if type(services.prompt) ~= "function" then return {ready = false, retry = true, reason = "promptUnavailable"} end
  local promptOk, result = pcall(services.prompt, dependency, installed ~= nil)
  if not promptOk or result == false then return {ready = false, retry = true, reason = "promptFailed"} end
  state.prompted[dependency.repoId] = true
  return {ready = false, retry = false, action = "prompted", modName = installedName}
end

function M.ensureRepositoryMod(dependency, services, state)
  services = services or defaultServices()
  state = state or runtimeState
  state.prompted = state.prompted or {}
  local mods, unavailable = listInstalledMods(services.modManager)
  if not mods then return unavailable end
  local installedName, installed = findInstalledMod(mods, dependency)
  if isModActive(installed) then return {ready = true, action = "active", modName = installedName} end
  return promptOnce(dependency, services, state, installedName, installed)
end

local function ensureDependenciesInternal()
  local allReady, retry = true, false
  for _, dependency in ipairs(dependencies) do
    local result = M.ensureRepositoryMod(dependency)
    allReady = allReady and result.ready
    retry = retry or result.retry == true
  end
  return allReady, retry
end

function M.ensureDependencies()
  local ready, retry = ensureDependenciesInternal()
  waitingForServices = retry
  retryElapsed, totalWait = 0, 0
  return ready
end

function M.onExtensionLoaded()
  M.ensureDependencies()
end

-- Retries once a second while the mod manager is still starting, and gives up after 30 seconds.
function M.onUpdate(dtReal)
  if not waitingForServices then return end
  local dt = math.max(0, tonumber(dtReal) or 0)
  retryElapsed, totalWait = retryElapsed + dt, totalWait + dt
  if retryElapsed < 1 then return end
  retryElapsed = 0
  local _, retry = ensureDependenciesInternal()
  waitingForServices = retry
  if totalWait >= 30 then waitingForServices = false end
end

M.repositoryDependencies = dependencies
return M
