-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- WARNING: This API is experimental and may change if we need to add/change features.
-- Use at your own risk as breaking changes may occur in future updates.

local M = {}
M.dependencies = {"ui_apps_minimap_topomap", "ui_apps_minimap_additionalInfo", "ui_apps_minimap_route", "ui_apps_minimap_utils", "ui_apps_minimap_roads", "ui_apps_minimap_vehicles", "gameplay_playmodeMarkers"}
local layers = require("ui/apps/minimap/layers")
local clrTransparent = color(0,0,0,0)
M.onInit = function()
  setExtensionUnloadMode(M, "manual")
  M.onMinimapSettingsChanged()
end

local mode = settings.getValue("minimapMode") or "circle" -- "circle" or "rect"
--extensions.load("test_imguiMinimap")
local im = ui_imgui
-- Add custom buffers for each direction (left, right, top, bottom)
local bufferLeft = 50
local bufferRight = 50
local bufferTop = 50
local bufferBottom = 50
local width, height -- w/h of the minimap in imgui coordinates
local centerX, centerY -- center of the minimap in imgui coordinates
local camPos, camRot, camRotInverse = vec3(), quat(), quat() -- camera transform
local cameraLook = vec3()
local scaleSetting = 0.5 -- px/m

local currentPlayerId = 0

local scale = scaleSetting
local scaleInverse = 1/scale
local sqr2 = math.sqrt(2)/2
-- map/roads cache



local td

local p = nil

M.getScale = function()
  return scale
end


local stats = { }
local function resetStats()
  stats.navgraphRoadsVisible = 0
  stats.roadsDrawnFG = 0
  stats.roadsDrawnBG = 0

  stats.totalLinesDrawn = 0
end
resetStats()

local debugSettingsOpen = false
local debugSettings = {
  drawRoadsBg = true,
  drawRoadsFg = true,
  drawNavigation = true,
  drawPlayer = true,
  drawOtherVehicles = true,
  drawParkedVehicles = false,
  drawTrafficVehicles = false,
  drawActivePoliceVehicles = true,
  drawPoliceInfo = true,
  drawCompass = true,
  draw100m = false,
  drawOcclusion = false,
  drawBounds = false,
  drawGrid = false,
  lookaheadEnabled = false,
  lookaheadValue = 3,

  drawPlaymodeMarkers = true,
  styleConstantWidth = true,
  styleRoadColorUnique = false,
  styleRoadColorAllWhite = false,
  styleRoadColorDrivability = true,
  behaviourRotateWithCam = true,
  useProfiler = false,
  useProfilerAlwaysLog = false,
  profileEveryNthFrame = 1,
}
local debugSettingsData = {
  lookaheadValue = {
    { name = "0%", value = 0.0 },
    { name = "low", value = 0.33 },
    { name = "medium", value = 0.55 },
    { name = "high", value = 0.77 },
  },
  profileEveryNthFrame = {
    { name = "off", value = 0 },
    { name = "10", value = 10 },
    { name = "20", value = 20 },
    { name = "30", value = 30 },
    { name = "40", value = 40 },
    { name = "50", value = 50 },
    { name = "100", value = 100 },
    { name = "200", value = 200 },
    { name = "300", value = 300 },
    { name = "400", value = 400 },
    { name = "500", value = 500 },
    { name = "1000", value = 1000 },
  },

}





-- Unoptimized
local tmp1, tmp2, tmp3, tmp4 = vec3(), vec3(), vec3(), vec3()
local centerLocal = vec3()
local worldYDirection = vec3(0,1,0)
local directionLocal = vec3()
local intersectionLocal = vec3()
local leftTop, leftBottom, rightTop, rightBottom, diagonalTop, diagonalBottom = vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local function drawCompass(offsetX, offsetY)
-- unoptimized
  -- Work in minimap's local coordinate system (before rotation)
  -- Use the actual minimap center coordinates, not the buffer offsets
  centerLocal:set(width/2, height/2, 0)

  -- Transform the Y+ direction vector through the minimap's rotation
  -- Apply the same transformation as worldToMapXYZ but for direction vectors
  directionLocal:set(worldYDirection)
  directionLocal:setScaled(1/scale)  -- Scale like in worldToMapXYZ
  directionLocal:setRotate(camRot)   -- Rotate like in worldToMapXYZ
  -- Note: we don't apply the translation (camPos offset) since this is a direction vector

  -- Flip Y coordinate to match minimap coordinate system
  directionLocal.y = -directionLocal.y

  directionLocal:normalize()

  -- Use the existing boundary detection system from utils
  -- First, calculate the target position in the direction of north
  local targetDistance = math.max(width, height) * 2  -- Use a large enough distance to ensure we hit the boundary
  intersectionLocal:set(centerLocal.x + directionLocal.x * targetDistance, centerLocal.y + directionLocal.y * targetDistance, 0)

  -- Now use the utils boundary detection to clamp this position properly
  -- This will handle both circle and rect modes correctly
  ui_apps_minimap_utils.setClampToBounds(intersectionLocal, -4)
  local dpi = im.GetWindowDpiScale()
  -- Draw circle with triangle pointing toward the marker (like walking marker)
  local circleRadius = 6 * dpi

  -- Draw circle at intersection point
  -- Convert from local coordinates to drawing coordinates by adding the offset
  local drawX = intersectionLocal.x
  local drawY = intersectionLocal.y
  td:circle(drawX, drawY, circleRadius, 3, ui_apps_minimap_utils.colors.grayMuted , ui_apps_minimap_utils.colors.grayMuted, ui_apps_minimap_utils.colors.navBgWhite, ui_apps_minimap_utils.colors.navBgWhite, 0, layers.COMPASS)

  -- Draw "N" inside the circle using lines
  local letterSize = circleRadius *1.5
  local centerX = drawX
  local centerY = drawY
  local strikeColor = ui_apps_minimap_utils.colors.navBgWhite


  -- Left vertical line of "N"
  leftTop:set(centerX - letterSize * 0.3, centerY + letterSize * 0.4, 0)
  leftBottom:set(centerX - letterSize * 0.3, centerY - letterSize * 0.4, 0)

  -- Right vertical line of "N"
  rightTop:set(centerX + letterSize * 0.3, centerY + letterSize * 0.4, 0)
  rightBottom:set(centerX + letterSize * 0.3, centerY - letterSize * 0.4, 0)

  -- Diagonal line of "N"
  diagonalTop:set(centerX + letterSize * 0.3, centerY + letterSize * 0.4, 0)
  diagonalBottom:set(centerX - letterSize * 0.3, centerY - letterSize * 0.4, 0)
  local lineWidth = 1
  -- Draw the three lines of "N"
  td:line(leftTop.x, leftTop.y, leftBottom.x, leftBottom.y, lineWidth, lineWidth, 0, 0, strikeColor, strikeColor, strikeColor, strikeColor, 0, layers.COMPASS)
  td:line(rightTop.x, rightTop.y, rightBottom.x, rightBottom.y, lineWidth, lineWidth, 0, 0, strikeColor, strikeColor, strikeColor, strikeColor, 0, layers.COMPASS)
  td:line(diagonalTop.x, diagonalTop.y, diagonalBottom.x, diagonalBottom.y, lineWidth, lineWidth, 0, 0, strikeColor, strikeColor, strikeColor, strikeColor, 0, layers.COMPASS)

  return true
end


local nearbyIds = {}
local function drawPlaymodeMarkers()
  local clusterKd = gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree()
  local radius = 1000
  table.clear(nearbyIds)
  for id in clusterKd:queryNotNested(camPos.x-radius, camPos.y-radius, camPos.x+radius, camPos.y+radius) do
    nearbyIds[id] = true
  end
  local dpi = im.GetWindowDpiScale()
  for i, cluster in ipairs(gameplay_playmodeMarkers.getPlaymodeClusters()) do
    local marker = gameplay_playmodeMarkers.getMarkerForCluster(cluster)
    if (nearbyIds[cluster.id] or marker.focus) then
      if marker.drawOnMinimap then
        marker:drawOnMinimap(td, dpi)
      else
        if marker.pos then
          ui_apps_minimap_utils.simpleCircle(marker.pos)
        end
      end
    end
  end
end

-- temp variables
local x,y, rad, areaPos
local occlusionTransforms = {}
local occlusionPixels = {}

local childSize = im.ImVec2(0,0)
local border = 0
local up = vec3(0,1,0)
local camRotInverse = quat()
local firstPass = true
local frameCount = 0
local imVec01 = im.ImVec2(0,1)
local lookWithoutZ = vec3()
local function drawMinimap(sizeX, sizeY, dtReal, dtSim)
  -- setup imgui and size variables
  local dpi = im.GetWindowDpiScale()
  --avail = im.GetContentRegionAvail()

  width, height = sizeX-bufferLeft-bufferRight, sizeY-bufferTop-bufferBottom
  width = width/dpi
  height = height/dpi
  childSize.x = width
  childSize.y = height
  areaPos = im.GetWindowPos()
  x,y = areaPos.x + bufferLeft, areaPos.y + bufferTop
  centerX, centerY = x + width/2, y+height/2

  x = x*dpi
  y = y*dpi
  width = width*dpi
  height = height*dpi

  -- Calculate offsets for the custom buffers
  local offsetX = bufferLeft
  local offsetY = bufferTop

  -- camera setup
  camPos:set(core_camera.getPositionXYZ())
  cameraLook:set(core_camera.getForwardXYZ())
  --cameraLook:setRotate(core_camera.getQuat())
  cameraLook.z = 0
  cameraLook:normalize()
  rad = -math.atan2(cameraLook.y, -cameraLook.x) + math.pi/2

  if debugSettings.behaviourRotateWithCam then
    camRot = quatFromEuler(0,0,rad)
  else
    camRot = quatFromEuler(0,0,0)
  end
  camRotInverse:set(camRot)
  camRotInverse:inverse()
  if debugSettings.lookaheadEnabled then
    local lookaheadValue = debugSettingsData.lookaheadValue[debugSettings.lookaheadValue].value
    lookWithoutZ:set(cameraLook.x, cameraLook.y, 0)
    lookWithoutZ:normalize()
    lookWithoutZ:setScaled(lookaheadValue * scale * height/2)
    camPos:setAdd(lookWithoutZ)
  end

  -- Update utils extension with current state
  if ui_apps_minimap_utils then
    ui_apps_minimap_utils.setMinimapState(width, height, centerX, centerY, camPos, camRot, camRotInverse, scale, scaleInverse, td, offsetX, offsetY, mode, dpi)
  end

  -- Update vehicles extension with current state
  if ui_apps_minimap_vehicles then
    ui_apps_minimap_vehicles.setMinimapState(width, height, centerX, centerY, camPos, camRot, camRotInverse, scale, scaleInverse, td, debugSettings, cameraLook, dpi)
  end


  im.Dummy(imVec01)
  if p then p:add("setup") end

  if ui_apps_sdfTopomap and ui_apps_sdfTopomap.isLoaded() then
    ui_apps_sdfTopomap.drawContours(td, width, height, scale, camPos, ui_apps_minimap_utils.worldToMapXYZ)
  end

  -- Draw grid (bottom layer)
  if debugSettings.drawGrid then
    ui_apps_minimap_utils.drawGrid()
    if p then p:add("Grid") end
  end

  -- first pass for background, then for roads
  local radius = math.max(width, height)*scale*sqr2
  firstPass = true
  ui_apps_minimap_roads.drawRoads(p, radius, td, debugSettings, camPos, scale, dpi) -- background
  --[[if debugSettings.drawRoadsBg then
    firstPass = false
    if p then p:add("Roads BG") end
  end

  if debugSettings.drawRoadsFg then
    ui_apps_minimap_roads.drawRoads(false, radius, td, debugSettings, camPos, scale, firstPass, dpi) -- roads
    firstPass = false
    if p then p:add("Roads FG") end
  end
  ]]

  -- Draw navigation route
  if debugSettings.drawNavigation and ui_apps_minimap_route then
    ui_apps_minimap_route.drawNavigationRoute(td, dpi)
    if p then p:add("Navigation") end
    ui_apps_minimap_route.drawRoutePointer(td)
    if p then p:add("Route Pointer") end
  end



  if debugSettings.draw100m then
    local w = 20
    td:circle(width/2 + offsetX,height/2 + offsetY, 100/scale-w, w, clrTransparent, clrTransparent, color(255,255,255,0),color(255,255,255,250), 0, layers.GAMEPLAY_MARKERS)
    if p then p:add("100mRadius") end
  end

  -- draw playmode markers
  if debugSettings.drawPlaymodeMarkers and gameplay_playmodeMarkers.isStateWithPlaymodeMarkers() then
    drawPlaymodeMarkers()
    if p then p:add("Playmode Markers") end
  end

  -- draw custom stuff
  extensions.hook("onDrawOnMinimap", td)

  currentPlayerId = be:getPlayerVehicleID(0)
  if ui_apps_minimap_vehicles then
    ui_apps_minimap_vehicles.drawOtherVehicles(dtReal, dtSim)
    if p then p:add("Other Vehicles") end

    local adjustedScale = ui_apps_minimap_vehicles.drawPlayer(dtReal, dtSim)
    scale = adjustedScale or scale or 1
    scaleInverse = 1/scale
    if p then p:add("Player") end
  end


  M.drawOcclusion(offsetX, offsetY)
  if p then p:add("Occlusion") end


  if debugSettings.drawCompass then
    drawCompass(offsetX, offsetY)
    if p then p:add("Compass") end
  end


  if debugSettings.drawBounds then
    M.drawDebugOverlay()
    if p then p:add("Debug Overlay") end
  end

end




-- imgui window setup
local lastSize = im.ImVec2(0,0)
local lastTexSize = im.ImVec2(0,0)
local drawTransform = {0,0,0,0}
local transparent = im.GetColorU322(im.ImVec4(0,0,0,0.0))
local padding = im.ImVec2(5,5)
local imPadding = 0

local point00 = Point2I(0,0)

local windowPos, windowSize = im.ImVec2(0,0), im.ImVec2(0,0)
local function draw(dtReal, dtSim)
  if editor and editor.active then return end
  if p then p:start() end
  -- setup imgui window position and size
  local canvasObject = scenetree.findObject("Canvas")
  local canvasPosX, canvasPosY = canvasObject:clientToScreenXY(point00)
  local canvasSizeX, canvasSizeY = canvasObject:getWindowClientSizeXY()
  bufferLeft, bufferRight, bufferTop, bufferBottom = 50, 50, 50, 50

  windowPos.x = canvasPosX + drawTransform[1] * canvasSizeX
  windowPos.y = canvasPosY + drawTransform[2] * canvasSizeY

  if windowPos.x - bufferLeft < canvasPosX then
    bufferLeft = windowPos.x - canvasPosX
  end
  if windowPos.y - bufferTop < canvasPosY then
    bufferTop = windowPos.y - canvasPosY
  end

  windowPos.x = windowPos.x - bufferLeft
  windowPos.y = windowPos.y - bufferTop

  windowSize.x = drawTransform[3] * canvasSizeX + bufferLeft
  windowSize.y = drawTransform[4] * canvasSizeY + bufferTop

  local bottom, right = windowPos.y + windowSize.y, windowPos.x + windowSize.x

  if right + bufferRight > canvasPosX + canvasSizeX then
    bufferRight = (canvasPosX + canvasSizeX) - right
  end
  if bottom + bufferBottom > canvasPosY + canvasSizeY then
    bufferBottom = (canvasPosY + canvasSizeY) - bottom
  end

  windowSize.x = windowSize.x + bufferRight
  windowSize.y = windowSize.y + bufferBottom

  im.SetNextWindowPos(windowPos, im.Cond_Always)
  im.SetNextWindowSize(windowSize, im.Cond_Always)

  im.PushStyleColor1(im.Col_WindowBg, debugSettings.drawBounds and im.GetColorU322(im.ImVec4(0,0,0,0.25)) or transparent)
  im.PushStyleColor1(im.Col_Border, debugSettings.drawBounds and im.GetColorU322(im.ImVec4(0,0,0,0.25)) or transparent)
  im.PushStyleColor1(im.Col_BorderShadow, debugSettings.drawBounds and im.GetColorU322(im.ImVec4(0,0,0,0.25)) or transparent)
  im.PushStyleVar2(im.StyleVar_WindowPadding, padding)
  if p then p:add("Canvas and window setup") end
  if im.Begin("SDF Minimap",nil, bit.bor(im.WindowFlags_NoScrollbar, im.WindowFlags_NoScrollWithMouse, im.WindowFlags_NoTitleBar, im.WindowFlags_NoResize, im.WindowFlags_NoMove, im.WindowFlags_NoInputs)) then

    local cp = im.GetCursorPos()
    local size = im.GetContentRegionAvail()
    local sizeX, sizeY = size.x, size.y
    size.x = size.x - imPadding*2
    size.y = size.y - imPadding*2
    local dpi = im.GetWindowDpiScale()
    if size.x > 0 and size.y > 0 then
      if size.x ~= lastSize.x or size.y ~= lastSize.y then
        local texSize = Point2I(math.floor((size.x+bufferLeft+bufferRight) / dpi), math.floor((size.y+bufferTop+bufferBottom) / dpi))
        texSize.x = windowSize.x
        texSize.y = windowSize.y
        td = TextureDrawPrimitiveRegistry:getOrCreate("sdfMinimap",texSize, false, ColorF(0,0,0,0))
        td:setWidthHeight(texSize.x, texSize.y)
        lastSize = size
        print(string.format("Size: %d, %d", size.x, size.y))
        print(string.format("TexSize: %d, %d", texSize.x, texSize.y))
        lastTexSize = texSize
      end

      table.clear(occlusionPixels)
      for id, transform in pairs(occlusionTransforms) do
        local x, y, width, height = transform[1], transform[2], transform[3], transform[4]
        local x1, y1 = x * canvasSizeX, y * canvasSizeY
        local x2, y2 = (x + width) * canvasSizeX, (y + height) * canvasSizeY
        transform[5], transform[6], transform[7], transform[8] = x1-windowPos.x+canvasPosX-cp.x, y1-windowPos.y+canvasPosY-cp.y, x2-windowPos.x+canvasPosX-cp.x, y2-windowPos.y+canvasPosY-cp.y
      end

      drawMinimap(sizeX, sizeY,dtReal, dtSim)
      cp.x = cp.x + imPadding
      cp.y = cp.y + imPadding
      im.SetCursorPos(cp)


      td:ImGui_Image(lastTexSize.x, lastTexSize.y)
      --im.Text(string.format("Window Size: %d, %d", windowSize.x, windowSize.y))
      --im.Text(string.format("Tex Size: %d, %d", lastTexSize.x, lastTexSize.y))
    end
    im.End()
  end
  im.PopStyleColor(3)
  im.PopStyleVar(1)
  if debugSettingsOpen then
    if p then p:add("debugSettings window") end
    if im.Begin("SDF Minimap debugSettings") then
      if im.Button("Close") then
        debugSettingsOpen = false
      end
      im.SameLine()
      if im.Button("Reset Stats") then
        resetStats()
      end
      im.SameLine()
      if im.Button("Load Topo Map") then
        ui_apps_sdfTopomap.loadTopoMap()
      end
      for _, key in ipairs(tableKeysSorted(stats)) do
        im.Text(string.format("%s: %d", key, stats[key]))
      end
      im.Separator()
      for _, key in ipairs(tableKeysSorted(debugSettings)) do
        if debugSettingsData[key] then
          im.Text(key)
          im.SameLine()
          if im.BeginCombo(key, debugSettingsData[key][debugSettings[key]].name) then
            for i, v in ipairs(debugSettingsData[key]) do
              if im.Selectable1(v.name) then
                debugSettings[key] = i
                if ui_apps_minimap_roads then
                  ui_apps_minimap_roads.reset()
                end
              end
            end
            im.EndCombo()
          end
        else
          if im.Checkbox(key, im.BoolPtr(debugSettings[key])) then
            debugSettings[key] = not debugSettings[key]
          end
        end
      end

      if not p and debugSettings.useProfiler then
        p = LuaProfiler("minimap Profiler")
      end
      frameCount = frameCount + 1
      if p and
        (debugSettings.useProfilerAlwaysLog
          or (debugSettings.profileEveryNthFrame > 0 and (frameCount % debugSettingsData.profileEveryNthFrame[debugSettings.profileEveryNthFrame].value == 0)))
        then p:finish(true) end
      if im.Button("Log Profiler") then
        if p then p:finish(true) end
      end
      if p and not debugSettings.useProfiler then
        p = nil
      end
      if p then p:finish(false) end
      im.End()
    end
  end
end

M.drawOcclusion = function(offsetX, offsetY)
  local white, transparent, flag = color(255,255,255,255), color(255,255,255,0),TextureDrawPrimitive_primitiveFlag_blendMultiply


  local dpi = im.GetWindowDpiScale()
  --td:circle(width/2 + offsetX-30, height/2 + offsetY, 50*dpi,20*dpi, white, white, transparent, transparent, flag, layers.DEBUG)
  --td:circle(width/2 + offsetX+30, height/2 + offsetY, 50*dpi,20*dpi, white, white, transparent, transparent, flag, layers.DEBUG)

  --transparent = color(255,0,0,128)
  --flag = nil

  for _, transform in pairs(occlusionTransforms) do
    --im.Text(string.format("Pixel: %d, %d, %d, %d", pixel[1], pixel[2], pixel[3], pixel[4]))
    local left, right, h = transform[5]+5, transform[7]-5, transform[8]-transform[6]
    td:line(left, transform[6]+h/2, right, transform[6]+h/2, h/2-5, h/2-5, 5, 5, transparent, transparent, white, white, flag, layers.ROUND_OR_SQUARE_MASK)
  end

  if debugSettings.drawOcclusion then
    for id, transform in pairs(occlusionTransforms) do
      im.Text(string.format("Occ %s: %0.3f, %0.3f, %0.3f, %0.3f", id, transform[1], transform[2], transform[3], transform[4]))
      local left, right, h = transform[5]+5, transform[7]-5, transform[8]-transform[6]
      td:line(left, transform[6]+h/2, right, transform[6]+h/2, h/2-5, h/2-5, 5, 5, color(255,0,0,128), color(255,0,0,128), color(255,0,0,255), color(255,0,0,128), 0, layers.DEBUG)
    end
  end


  local roundness, strikeWidth = 10, 100
  local buffer = 5

  if mode == "circle" then
    -- crop to circle
    td:circle(width/2 + offsetX, height/2 + offsetY, width/2, width*2, white, white, transparent, transparent, flag, layers.ROUND_OR_SQUARE_MASK)
    td:circle(width/2 + offsetX, height/2 + offsetY, width/2-10*dpi,   12*dpi, white, white, white, transparent, flag, layers.ROUND_OR_SQUARE_MASK)
    if debugSettings.drawOcclusion then
      td:circle(width/2 + offsetX,height/2 + offsetY, width/2, 20, color(255,0,0,128), color(255,0,0,128), color(255,0,0,255), color(255,0,0,128), 0, layers.DEBUG)

      --td:circle(width/2 + offsetX,height/2 + offsetY, width/2-10*dpi, 11*dpi, color(255,0,0,128), color(255,0,0,128), color(255,0,0,255), color(255,0,0,128), 0, layers.DEBUG)

    end
  end
  if mode == "rect" then

    td:line(bufferLeft+buffer*1.5, bufferTop+height/2, width+bufferLeft-buffer*1.5, bufferTop+height/2, height/2-buffer*2, height/2-buffer*2, roundness, strikeWidth, white, white, transparent, transparent, flag, layers.ROUND_OR_SQUARE_MASK)

    roundness, strikeWidth = 5, 10
    buffer = 5

    td:line(bufferLeft+buffer*1.5, bufferTop+height/2, width+bufferLeft-buffer*1.5, bufferTop+height/2, height/2-buffer*2, height/2-buffer*2, roundness, strikeWidth, white, white, white, transparent, flag, layers.ROUND_OR_SQUARE_MASK)
  end

end

M.drawDebugOverlay = function()
  local texWidth, texHeight = width + bufferLeft + bufferRight, height + bufferTop + bufferBottom

  td:circle(0,0, 5,5, clrTransparent, clrTransparent, color(0,255,0,255), color(0,255,0,255), 0, layers.DEBUG)
  td:circle(texWidth ,0, 5,5, clrTransparent, clrTransparent, color(0,255,0,255), color(0,255,0,255), 0, layers.DEBUG)
  td:circle(0,texHeight , 5,5, clrTransparent, clrTransparent, color(0,255,0,255), color(0,255,0,255), 0, layers.DEBUG)
  td:circle(texWidth ,texHeight , 5,5, clrTransparent, clrTransparent, color(0,255,0,255), color(0,255,0,255), 0, layers.DEBUG)


  td:circle(bufferLeft ,bufferTop, 5,5, clrTransparent, clrTransparent, color(255,255,255,255), color(255,255,255,255), 0, layers.DEBUG)
  td:circle(width + bufferLeft ,bufferTop, 5,5, clrTransparent, clrTransparent, color(255,255,255,255), color(255,255,255,255), 0, layers.DEBUG)
  td:circle(bufferLeft ,height + bufferTop, 5,5, clrTransparent, clrTransparent, color(255,255,255,255), color(255,255,255,255), 0, layers.DEBUG)
  td:circle(width + bufferLeft ,height + bufferTop, 5,5, clrTransparent, clrTransparent, color(255,255,255,255), color(255,255,255,255), 0, layers.DEBUG)

  td:circle(bufferLeft/2, texHeight/2, bufferLeft/2, 1, clrTransparent, clrTransparent, color(255,0,0,255), color(255,0,0,255), 0, layers.DEBUG)
  td:circle(texWidth/2,bufferTop/2, bufferTop/2, 1, clrTransparent, clrTransparent, color(255,0,0,255), color(255,0,0,255), 0, layers.DEBUG)
  td:circle(texWidth-bufferRight/2,texHeight/2, bufferRight/2, 1, clrTransparent, clrTransparent, color(255,0,0,255), color(255,0,0,255), 0, layers.DEBUG)
  td:circle(texWidth/2,texHeight-bufferBottom/2, bufferBottom/2, 1, clrTransparent, clrTransparent, color(255,0,0,255), color(255,0,0,255), 0, layers.DEBUG)

  im.Text(string.format("Buffers: %d, %d, %d, %d", bufferLeft, bufferRight, bufferTop, bufferBottom))
  im.Text(string.format("Width: %d, Height: %d", width, height))
  im.Text(string.format("TexWidth: %d, TexHeight: %d", texWidth, texHeight))

end

-- Public API

local function getMode()
  return mode
end
M.getMode = getMode

local lookaheadValues = {
  disabled = 1,
  low = 2,
  medium = 3,
  high = 4
}
local function onMinimapSettingsChanged(m)
  mode = settings.getValue("minimapMode")
  debugSettings.behaviourRotateWithCam = settings.getValue("minimapOrientation") == "rotateWithCamera"
  debugSettings.drawGrid = settings.getValue("minimapDrawGrid") == "always"
  debugSettings.lookaheadEnabled = settings.getValue("minimapLookahead") ~= "disabled"
  debugSettings.lookaheadValue = lookaheadValues[settings.getValue("minimapLookahead")] or 0

  if mode ~= "circle" and mode ~= "rect" then
    mode = "rect"
  end
end
-- Function to set custom buffers for each direction
local function setBuffers(left, right, top, bottom)
  bufferLeft = left or 100
  bufferRight = right or 100
  bufferTop = top or 100
  bufferBottom = bottom or 100
end

local function setDrawTransform(x, y, width, height)
  if x < 0 or x > 1 or y < 0 or y > 1 or width < 0 or width > 1 or height < 0 or height > 1 then
    log("W","",string.format("Invalid minimap transform: %0.5f, %0.5f, %0.5f, %0.5f", x, y, width, height))
    M.hide()
    return
  end
  drawTransform = {x, y, width, height}
  log("I","",string.format("Setting minimap transform to: %0.5f, %0.5f, %0.5f, %0.5f", x, y, width, height))
  if M.onUpdate == nil then
    M.onUpdate = draw
    extensions.hookUpdate("onUpdate")
  end
end
local function setOcclusionTransform(id, x, y, width, height)
  occlusionTransforms[id] = {x, y, width, height}
  if x > 1 or x < 0 or y > 1 or y < 0 or width > 1 or width < 0 or height > 1 or height < 0 then
    log("W","",string.format("Invalid minimap occlusion transform: %0.5f, %0.5f, %0.5f, %0.5f", x, y, width, height))
    occlusionTransforms[id] = nil
  end
end
M.setOcclusionTransform = setOcclusionTransform
local function resetOcclusionTransform(id)
  if type(id) == "string" and id ~= "" then
    occlusionTransforms[id] = nil
  else
    occlusionTransforms = {}
  end
end
M.resetOcclusionTransform = resetOcclusionTransform

local function hide()
  drawTransform = {0,0,0,0}
  if M.onUpdate then
    M.onUpdate = nil
    extensions.hookUpdate("onUpdate")
  end
end

local function toggledebugSettings()
  debugSettingsOpen = not debugSettingsOpen
end

M.setDrawTransform = setDrawTransform
M.setBuffers = setBuffers
M.onUpdate = nil
M.hide = hide
M.toggledebugSettings = toggledebugSettings
M.onMinimapSettingsChanged = onMinimapSettingsChanged

-- Getter for debugSettingsData
M.getDebugSettingsData = function()
  return debugSettingsData
end

M.onClientEndMission = function()
  M.hide()
  if ui_apps_minimap_roads then
    ui_apps_minimap_roads.reset()
  end

end

M.onClientStartMission = function()
  M.hide()
  if ui_apps_minimap_roads then
    ui_apps_minimap_roads.reset()
  end

end

return M

