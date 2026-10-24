-- Ground-marker route tokens, claims and repair across level and extension changes.
-- Read ownership and patch state, token operations, repair, then lifecycle hooks.

local M = {}
M.dependencies = {'core_groundMarkers', 'overhaul_shell_patches'}

local PATCH_ID = 'groundMarkerOwnership'

local origSetPath
local claims = {}
local generation = 0
local lastReseedAt = 0
local RESEED_INTERVAL = 0.5

local function currentGeneration()
  return generation
end

local function bump()
  generation = generation + 1
  return generation
end

local function hasActiveDestination()
  local groundMarkers = rawget(_G, 'core_groundMarkers')
  return groundMarkers ~= nil and groundMarkers.endWP ~= nil
end

-- Holds do not replace generation tokens: a hold protects guidance, a token authorizes clearing it.
local function claim(ownerId, opts)
  if type(ownerId) ~= 'string' or ownerId == '' then return false end
  claims[ownerId] = opts or claims[ownerId] or {}
  return true
end

local function release(ownerId)
  if ownerId == nil or claims[ownerId] == nil then return false end
  claims[ownerId] = nil
  return true
end

local function isClaimed()
  return next(claims) ~= nil
end

local function hasRoutePath()
  local groundMarkers = rawget(_G, 'core_groundMarkers')
  local path = groundMarkers and groundMarkers.routePlanner and groundMarkers.routePlanner.path
  return path ~= nil and path[1] ~= nil and path[1].pos ~= nil
end

local function reseedIfNeeded()
  if isClaimed() or not origSetPath or not hasActiveDestination() or hasRoutePath() then
    return
  end
  local now = os.clockhp and os.clockhp() or os.time()
  if (now - lastReseedAt) < RESEED_INTERVAL then
    return
  end
  lastReseedAt = now
  local groundMarkers = rawget(_G, 'core_groundMarkers')
  origSetPath(groundMarkers.endWP, {
    clearPathOnReachingTarget = groundMarkers.clearPathOnReachingTarget,
    step = groundMarkers.stepDistance,
    color = groundMarkers.color,
    cutOffDrivability = groundMarkers.cutOffDrivability,
    penaltyAboveCutoff = groundMarkers.penaltyAboveCutoff,
    penaltyBelowCutoff = groundMarkers.penaltyBelowCutoff,
    renderDecals = groundMarkers.renderDecals,
  })
end

local function clearOwnedPath(token)
  if token == nil or token ~= generation then
    return false
  end
  origSetPath(nil)
  bump()
  return true
end

local wrappers = {
  setPath = function(original)
    if type(original) ~= 'function' then return end
    origSetPath = original
    -- A newly loaded ground marker module starts a new route generation.
    bump()
    return function(wp, options)
      options = options or {}
      if wp == nil and options.generationToken ~= nil and options.generationToken ~= generation then
        return false
      end
      original(wp, options)
      return bump()
    end
  end,
  resetAll = function(original)
    if type(original) ~= 'function' then return end
    return function(...)
      original(...)
      bump()
    end
  end,
  sendToApp = function(original)
    if type(original) ~= 'function' then return end
    return function(...)
      if hasActiveDestination() and not hasRoutePath() then
        return
      end
      return original(...)
    end
  end,
  generateRouteDecals = function(original)
    if type(original) ~= 'function' then return end
    return function(startPos, ...)
      if not hasRoutePath() then
        return
      end
      return original(startPos, ...)
    end
  end,
  onPreRender = function(original)
    if type(original) ~= 'function' then return end
    return function(dt, ...)
      local groundMarkers = rawget(_G, 'core_groundMarkers')
      if groundMarkers and groundMarkers.endWP then
        if not isClaimed() and not hasRoutePath() then
          local veh = getPlayerVehicle(0)
          if veh and groundMarkers.routePlanner and groundMarkers.routePlanner.trackVehicle then
            groundMarkers.routePlanner:trackVehicle(veh)
          end
          reseedIfNeeded()
        end
        if not hasRoutePath() then
          return
        end
      end
      return original(dt, ...)
    end
  end,
  clearOwnedPath = function() return clearOwnedPath end,
  getPathGeneration = function() return currentGeneration end,
}

local function onExtensionLoaded()
  overhaul_shell_patches.registerFields(PATCH_ID, function() return rawget(_G, 'core_groundMarkers') end, wrappers)
end

local function onExtensionUnloaded()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
  origSetPath = nil
  claims = {}
end

M.claim = claim
M.release = release
M.isClaimed = isClaimed
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
