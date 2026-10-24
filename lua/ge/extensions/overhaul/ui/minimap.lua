-- Minimap behaviour of the Overhaul career: the vehicle layer and the off-map position clamp.
-- Swaps the stock minimap's draw and transform functions while Overhaul runs, and restores them on stop.
local M = {}

M.dependencies = {"overhaul_shell_patches"}

local vehicles = require("overhaul/ui/minimap/minimapVehicles")

-- The vehicle layer is a required library, so its metadata hooks live on this extension.
M.onFileChangedEnd = vehicles.clearModelCache
M.onModActivated = vehicles.clearModelCache
M.onModDeactivated = vehicles.clearModelCache
M.onModManagerReady = vehicles.clearModelCache
M.onVehicleSpawned = vehicles.clearModelCache
M.onVehicleReplaced = vehicles.clearModelCache

local PATCH_ID = "minimap"
-- Positions beyond this, and NaN, are drawn at the map centre.
local OFF_MAP_LIMIT = 1e6

local halfWidth, halfHeight = 0, 0
-- Captured from the game's setMinimapState; camPos is read per call, as the game reads it.
local camPos, scaleInverse
local fwdX, fwdY, rightX, rightY = 1, 0, 0, 1
-- Built on first capture, because vec3 only exists once the game runs.
local fwd, right
local stockXY, stockXYZ
-- True while the inline copy below gave the game's result for this frame's probe.
local inline = false
local probeTarget = {set = function(self, x, y, z) self.x, self.y, self.z = x, y, z end}
local probeSource = {x = 0, y = 0, z = 0}
local drawDepth = 0
-- Filled by onExtensionLoaded. The draw swap is created first and refreshed by the renderer hook.
local swaps = {}
local drawSwap = {}

-- The stock map transform written out, so the road layer skips a call for each segment.
local function inlineXY(x, y)
  x = (x - camPos.x) * scaleInverse
  y = (y - camPos.y) * scaleInverse
  local tX = x
  x = halfWidth + (tX * fwdX + y * rightX)
  y = halfHeight - (tX * fwdY + y * rightY)
  return x, y
end

local function isOnMap(x, y)
  return x >= -OFF_MAP_LIMIT and x <= OFF_MAP_LIMIT and y >= -OFF_MAP_LIMIT and y <= OFF_MAP_LIMIT
end

-- Probes the inline copy against the game for one point each frame; a changed game makes the inline copy stand down.
local function captureTransform(cameraPos, cameraRot, mapScaleInverse)
  inline = false
  local cameraPosType = type(cameraPos)
  if (cameraPosType ~= "table" and cameraPosType ~= "cdata") or not cameraRot or type(mapScaleInverse) ~= "number"
      or not stockXY or not stockXYZ then
    return
  end
  if not fwd then fwd, right = vec3(), vec3() end
  fwd:set(1, 0, 0)
  fwd:setRotate(cameraRot)
  right:set(0, 1, 0)
  right:setRotate(cameraRot)
  camPos, scaleInverse = cameraPos, mapScaleInverse
  fwdX, fwdY, rightX, rightY = fwd.x, fwd.y, right.x, right.y

  local probeX, probeY = cameraPos.x + 31.25, cameraPos.y - 17.5
  local gameX, gameY = stockXY(probeX, probeY)
  local inlineProbeX, inlineProbeY = inlineXY(probeX, probeY)
  if gameX ~= inlineProbeX or gameY ~= inlineProbeY then return end
  probeSource.x, probeSource.y = probeX, probeY
  stockXYZ(probeTarget, probeSource)
  inline = probeTarget.x == inlineProbeX and probeTarget.y == inlineProbeY and probeTarget.z == 0
end

-- A stock function replaced by a factory that ignores the original and returns the given function.
local function replacedBy(replacement)
  return function()
    return replacement
  end
end

local vehicleSwap = {
  setMinimapState = replacedBy(function(...) return vehicles.setMinimapState(...) end),
  drawPlayer = replacedBy(function(...) return vehicles.drawPlayer(...) end),
  drawOtherVehicles = replacedBy(function(...) return vehicles.drawOtherVehicles(...) end),
}

-- The transforms run for every road segment each frame, so they check the patch state themselves.
local utilsSwap = {
  setMinimapState = function(original)
    return function(viewWidth, viewHeight, centerX, centerY, cameraPos, cameraRot, cameraRotInverse, mapScale,
        mapScaleInverse, textureDraw, offsetX, offsetY, ...)
      halfWidth = (viewWidth or 0) * 0.5 + (offsetX or 0)
      halfHeight = (viewHeight or 0) * 0.5 + (offsetY or 0)
      local result = original(viewWidth, viewHeight, centerX, centerY, cameraPos, cameraRot, cameraRotInverse, mapScale,
        mapScaleInverse, textureDraw, offsetX, offsetY, ...)
      captureTransform(cameraPos, cameraRot, mapScaleInverse)
      return result
    end
  end,
  worldToMapXYZ = function(original, _, state)
    stockXYZ = original
    return function(target, source)
      if inline and state.active then
        local x, y = inlineXY(source.x, source.y)
        if not isOnMap(x, y) then x, y = halfWidth, halfHeight end
        target:set(x, y, 0)
        return
      end
      if not state.active then return original(target, source) end
      original(target, source)
      if not isOnMap(target.x, target.y) then target:set(halfWidth, halfHeight, 0) end
    end, true
  end,
  worldToMapXY = function(original, _, state)
    stockXY = original
    return function(x, y)
      if inline and state.active then
        x, y = inlineXY(x, y)
      else
        x, y = original(x, y)
        if not state.active then return x, y end
      end
      if not isOnMap(x, y) then return halfWidth, halfHeight end
      return x, y
    end, true
  end,
}

local markerSwap = {
  isStateWithPlaymodeMarkers = function(original, markers)
    return function(...)
      local enabled = original(...)
      if drawDepth == 0 or not enabled then return enabled end
      local tree = markers.getPlaymodeClustersAsQuadtree()
      return tree and tree.tree ~= nil and tree.nonLeafLimIdx ~= nil or false
    end
  end,
}

local rendererSwap = {
  setDrawTransform = function(original)
    return function(...)
      original(...)
      drawSwap.refresh()
    end
  end,
}

-- Counts the draw in progress, so the marker swap only applies inside the minimap's own draw.
local drawWrappers = {
  onUpdate = function(original)
    return function(...)
      drawDepth = drawDepth + 1
      local ok, err = pcall(original, ...)
      drawDepth = drawDepth - 1
      if not ok then error(err, 0) end
    end
  end,
}

local function install()
  inline = false
  for _, swap in ipairs(swaps) do swap.install() end
end

local function uninstall()
  for _, swap in ipairs(swaps) do swap.uninstall() end
end

local function refresh()
  for _, swap in ipairs(swaps) do swap.refresh() end
end

-- Stores the install, uninstall and refresh functions of one swap on `into`.
local function makeSwap(into, resolve, wrappers)
  into.install, into.uninstall, into.refresh = overhaul_shell_patches.fieldSwap(resolve, wrappers)
  return into
end

M.onExtensionLoaded = function()
  makeSwap(drawSwap, function()
    local renderer = ui_apps_minimap_minimap
    if renderer and type(renderer.onUpdate) == "function" then return renderer end
  end, drawWrappers)
  swaps[1] = makeSwap({}, function() return ui_apps_minimap_vehicles end, vehicleSwap)
  swaps[2] = makeSwap({}, function() return ui_apps_minimap_utils end, utilsSwap)
  swaps[3] = makeSwap({}, function() return gameplay_playmodeMarkers end, markerSwap)
  swaps[4] = makeSwap({}, function() return ui_apps_minimap_minimap end, rendererSwap)
  swaps[5] = drawSwap
  overhaul_shell_patches.register(PATCH_ID, install, uninstall, refresh)
end

M.onExtensionUnloaded = function()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

return M
