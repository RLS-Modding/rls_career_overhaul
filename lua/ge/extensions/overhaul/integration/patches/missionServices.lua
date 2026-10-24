-- Silences the game's mission provider while a career runs, since Overhaul has no missions.
-- The stock provider is loaded by stock chains, not by Overhaul, so the swap installs once it exists.
local M = {}
M.dependencies = {"overhaul_shell_patches"}

local PATCH_ID = "missionServices"
local PROVIDER = "gameplay_missions_missions"

local registered = false
local patchRegistry
local swap = {}
local swappedProvider

local function isActive()
  return overhaul_career_career and overhaul_career_career.isActive()
end

local function silenced(original)
  if type(original) ~= "function" then return end
  return function(...)
    if isActive() then return end
    return original(...)
  end
end

local function clearPois()
  if gameplay_rawPois then gameplay_rawPois.clear() end
end

-- The raw POI cache is dropped whenever the provider changes, so stale mission POIs never linger.
local function install()
  swap.install()
  swappedProvider = swap.provider()
  clearPois()
end

local function uninstall()
  swap.uninstall()
  swappedProvider = nil
  clearPois()
end

-- The shell refreshes on-demand modules when they appear or are replaced (level reload).
local function refresh()
  swap.refresh()
  local current = swap.provider()
  if current ~= swappedProvider then
    swappedProvider = current
    clearPois()
  end
end

local function registerProviderSwap()
  patchRegistry = overhaul_shell_patches
  swap.provider = patchRegistry.onDemandExtension(PROVIDER)
  swap.install, swap.uninstall, swap.refresh = patchRegistry.fieldSwap(swap.provider, {
    onGetRawPoiListForLevel = silenced,
    onActivityAcceptGatherData = silenced,
  })
  patchRegistry.register(PATCH_ID, install, uninstall, refresh)
end

function M.onExtensionLoaded()
  if registered then return end
  registerProviderSwap()
  registered = true
end

function M.onExtensionUnloaded()
  if registered then patchRegistry.unregister(PATCH_ID) end
  registered = false
end

return M
