-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local layers = require("ui/apps/minimap/layers")

-- Route path storage
local routePath = {}
local routeMaxLength = 3000 -- limit the route to 3000 points
local routeCurrentLength = 0
for i = 1, routeMaxLength do
  routePath[i] = vec3()
end

--local navBgWhite, navFgBlue

local clrNavBg = color(255,255,255,255)
local clrNavFg = color(0,0.4*255,1*255,255)
local clrTransparent = color(0,0,0,0)

local blendDistance = 75
local function getRouteColor(distance)
  if distance > blendDistance then
    return clrNavFg
  else
    -- blend between colorNavFG and white
    local t = (1 - distance / blendDistance) * 0.66
    return color(
      t*255,
      (0.4 + 0.6*t)*255,
      255, 255)
  end
end

local function drawRoute(route, td, dpi)
  dpi = dpi or 1
  if not route or not route[1] then
    return
  end
  --local currentStyleColorSet = ui_apps_minimap_utils.getCurrentStyleColors()
  --navBgWhite = navBgWhite or currentStyleColorSet.navBg
  --navFgBlue = navFgBlue or currentStyleColorSet.navFg
  local startDistance = route[1].distToTarget
  routeCurrentLength = math.min(#route, routeMaxLength)
  for i = 1, routeCurrentLength do
    ui_apps_minimap_utils.worldToMapXYZ(routePath[i], route[i].pos)
  end
  for i = 1, routeCurrentLength-1 do
    td:lineRoundEnd(routePath[i].x, routePath[i].y, routePath[i+1].x, routePath[i+1].y, 4*dpi, 4*dpi, 0, clrNavBg, clrNavBg, clrTransparent, clrTransparent, 0, layers.ROUTE_BG)
  end
  for i = 1, routeCurrentLength-1 do
    local color = getRouteColor(((startDistance - route[i].distToTarget) + (startDistance - route[i+1].distToTarget))/2)
    td:lineRoundEnd(routePath[i].x, routePath[i].y, routePath[i+1].x, routePath[i+1].y, 2*dpi, 2*dpi, 0, color, color, clrTransparent, clrTransparent, 0, layers.ROUTE_FG)
  end

end

-- Navigation drawing function
local routeOverrides = {}
local function drawNavigationRoute(td, dpi)
  dpi = dpi or 1
  table.clear(routeOverrides)
  extensions.hook("onMinimapRouteOverride", routeOverrides)
  if next(routeOverrides) then
    for _, route in ipairs(routeOverrides) do
      drawRoute(route, td, dpi)
    end
  else
    local rp = core_groundMarkers.routePlanner
    if rp and rp.path and rp.path[1] then
      drawRoute(rp.path, td, dpi)
    end
  end
end

local function drawRoutePointer(td)
  local rp = core_groundMarkers.routePlanner
  if not rp or not rp.path or not rp.path[1] then
    return
  end
  local route = rp.path
  --local currentStyleColorSet = ui_apps_minimap_utils.getCurrentStyleColors()
  --navBgWhite = navBgWhite or currentStyleColorSet.navBg
  --navFgBlue = navFgBlue or currentStyleColorSet.navFg
  ui_apps_minimap_utils.simpleCircleWithEdgePointer(route[#route].pos, clrNavFg, clrNavBg, 9)
end

M.drawNavigationRoute = drawNavigationRoute
M.drawRoutePointer = drawRoutePointer
return M