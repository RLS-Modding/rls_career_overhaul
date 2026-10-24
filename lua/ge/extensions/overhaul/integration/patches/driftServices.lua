-- Hides the game's drift spots while Overhaul runs by wrapping their hooks, and restores them on exit.
-- Wrappers are rebound when the game replaces its drift spot module (level reload or drift context change).
local M = {}
M.dependencies = {"overhaul_shell_patches"}

-- The drift modules must not be dependencies: a manual-unload dependency chain would keep them across levels.

local PATCH_ID = "driftServices"
local HOOK_NAMES = {"onGetRawPoiListForLevel", "detectStart", "onClientStartMission", "onUpdate"}

local bindings = {}
local state
local registered = false
local patchRegistry

local function isActive()
  return overhaul_career_career and overhaul_career_career.isActive()
end

local function currentDriftSpots()
  return rawget(_G, "gameplay_drift_freeroam_driftSpots")
end

local function clearRawPois()
  if gameplay_rawPois then gameplay_rawPois.clear() end
end

local function restoreBinding(binding)
  if binding.target[binding.key] == binding.wrapper then binding.target[binding.key] = binding.original end
  extensions.hookUpdate(binding.key)
end

local function uninstall()
  if state then state.enabled = false end
  for _, binding in ipairs(bindings) do restoreBinding(binding) end
  if next(bindings) then clearRawPois() end
  bindings, state = {}, nil
end

-- A wrapper hands the call back to the game only while the installed state is still enabled and Overhaul is off.
local function wrapHook(original, installedState)
  return function(...)
    if installedState.enabled and isActive() then return end
    return original(...)
  end
end

local function bindHook(target, key, installedState)
  local original = target[key]
  if type(original) ~= "function" then return end
  local wrapper = wrapHook(original, installedState)
  bindings[#bindings + 1] = {target = target, key = key, original = original, wrapper = wrapper}
  target[key] = wrapper
  extensions.hookUpdate(key)
end

local function install()
  local target = currentDriftSpots()
  if not target then return end
  if isActive() and target.onClientEndMission then target.onClientEndMission() end
  state = {enabled = true}
  for _, key in ipairs(HOOK_NAMES) do bindHook(target, key, state) end
  clearRawPois()
end

-- The game loads and unloads its drift spots with the drift context; follow it like the RLS override did.
local function refresh()
  local target = currentDriftSpots()
  if bindings[1] and bindings[1].target == target then return end
  uninstall()
  if target then install() end
end

function M.onExtensionLoaded()
  if registered then return end
  patchRegistry = overhaul_shell_patches
  patchRegistry.register(PATCH_ID, install, uninstall, refresh)
  registered = true
end

function M.onExtensionUnloaded()
  if registered then patchRegistry.unregister(PATCH_ID) end
  uninstall()
  registered = false
end

return M
