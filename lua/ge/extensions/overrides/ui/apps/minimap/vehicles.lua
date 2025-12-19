-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local layers = require("ui/apps/minimap/layers")
local clrTransparent = color(0,0,0,0)

-- Vehicle drawing state variables
local lastPos, lastPos2, pos, fwd, scl = vec3(), vec3(), vec3(), vec3(), vec3()
local f, bl, br, bc, side = vec3(), vec3(), vec3(), vec3(), vec3()
local lastDtSim, lastVel = 0, 0
local vehicleData, vel, scl
local stoppedScale = 0.5
local localUp = vec3(0,0,1)
local localFwd = vec3(0,1,0)
local velSmoother = newTemporalSmoothing(0.25,0.5, nil, 1)
local walkSmoother = newTemporalSmoothing(2,1, nil, 1)
local playerVehicle = nil
local currentPlayerId = 0
local scaleSetting = 0.5 -- px/m

local tmp1, tmp2, tmp3 = vec3(), vec3(), vec3()

-- State variables that need to be set by the main minimap
local width, height, centerX, centerY
local camPos, camRot, camRotInverse, scale, scaleInverse
local td, debugSettings, cameraLook
local dpi = 1

-- Setter function to update state from main minimap
M.setMinimapState = function(w, h, cx, cy, cp, cr, cri, s, si, textureDraw, debugSettingsObj, cameraLookObj, dpiValue)
  width = w
  height = h
  centerX = cx
  centerY = cy
  camPos = cp
  camRot = cr
  camRotInverse = cri
  scale = s
  scaleInverse = si
  td = textureDraw
  debugSettings = debugSettingsObj
  cameraLook = cameraLookObj
  dpi = dpiValue or 1
  dpi = dpi * (globalDpi or 1)
end

local function drawVehicle(pos, fwd, color, size, asCircle, layer)
  -- Get current style colors
  local currentStyleColorSet = ui_apps_minimap_utils.getCurrentStyleColors()
  if not currentStyleColorSet then
    -- Fallback to utils colors if StyleColorSet is not available
    currentStyleColorSet = ui_apps_minimap_utils.colors
  end

  layer = layer or layers.VEHICLES_OTHER

  -- Draw the three lines forming the triangle
  if asCircle then
    scl = scale*4 * size * dpi
    f:set(fwd)
    f:setScaled(2*scl)
    f:setAdd(pos)

    side:set(fwd)
    side:setCross(side, localUp)
    side.z = 0
    side:normalize()
    tmp2:set(side)
    tmp2:setScaled(1*scl)
    bl:set(pos)
    bl:setSub(tmp2)
    br:set(pos)
    br:setAdd(tmp2)
    ui_apps_minimap_utils.worldToMapXYZ(f,f)
    ui_apps_minimap_utils.worldToMapXYZ(bl,bl)
    ui_apps_minimap_utils.worldToMapXYZ(br,br)
    -- Draw the circle
    tmp1:set(pos)
    ui_apps_minimap_utils.worldToMapXYZ(tmp1,tmp1)

    local borderWidth = math.max(1, math.floor(2 * dpi))
    td:triangle(f.x, f.y, bl.x, bl.y, br.x, br.y, borderWidth, 0, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, 0, layer)
    td:circle(tmp1.x, tmp1.y, (5*size+2) * dpi, 0, currentStyleColorSet.navBg, currentStyleColorSet.navBg, clrTransparent, clrTransparent, 0, layer)

    td:triangle(f.x, f.y, bl.x, bl.y, br.x, br.y, 0, 0, color, color, color, color, 0, layer)
    td:circle(tmp1.x, tmp1.y, 5*size * dpi, 0, color, color, clrTransparent, clrTransparent, 0, layer)
  else
    scl = scale*7 * size * dpi

    side:set(fwd)
    side:setCross(side, localUp)
    side.z = 0
    side:normalize()
    f:set(fwd)
    f:setScaled(1.5*scl)
    f:setAdd(pos)
    bc:set(fwd)
    bc:setScaled(-scl)
    bc:setAdd(pos)

    tmp1:set(fwd)
    tmp1:setScaled(1.5*scl)
    tmp2:set(side)
    tmp2:setScaled(1*scl)
    bl:set(pos)
    bl:setSub(tmp1)
    bl:setSub(tmp2)
    br:set(pos)
    br:setSub(tmp1)
    br:setAdd(tmp2)

    -- Convert world points to map coordinates
    ui_apps_minimap_utils.worldToMapXYZ(f,f)
    ui_apps_minimap_utils.worldToMapXYZ(bl,bl)
    ui_apps_minimap_utils.worldToMapXYZ(br,br)
    ui_apps_minimap_utils.worldToMapXYZ(bc,bc)

    local border = math.max(1, math.floor(2 * dpi))

    td:triangle(f.x, f.y, bl.x, bl.y, bc.x, bc.y, border + 1, 0, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, 0, layer)
    td:triangle(bc.x, bc.y, br.x, br.y, f.x, f.y, border + 1, 0, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, 0, layer)

    td:triangle(f.x, f.y, bl.x, bl.y, bc.x, bc.y, 1, 0, color, color, color, color, 0, layer)
    td:triangle(bc.x, bc.y, br.x, br.y, f.x, f.y, 1, 0, color, color, color, color, 0, layer)
  end
end

local rot = quat()
local function drawPlayer(dtReal, dtSim)
  --playerVehicle = getPlayerVehicle(0)
  local isWalking = gameplay_walk.isWalking()
  if isWalking then
    pos:set(gameplay_walk.getPosXYZ())
    rot:set(gameplay_walk.getRotXYZW())
    fwd:setRotate(rot, localFwd)
    fwd.z = 0
    fwd:normalize()
  else
    local vehId = be:getPlayerVehicleID(0)
    if not vehId then return end
    vehicleData = map.objects[vehId] or nil
    if not vehicleData then return end
    pos:set(vehicleData.pos)
    fwd:set(vehicleData.dirVec.x,vehicleData.dirVec.y,0)
    fwd:normalize()
  end

  vel = (dtSim>0.0001) and (lastPos:distance(lastPos2) / lastDtSim) or lastVel
  local dynamicScale = clamp(velSmoother:get(vel > 10 and 3.0 or 1, dtReal), 1, 1.75)
  local walkScale = walkSmoother:get(isWalking and 0 or 1, dtReal)
  dynamicScale = smoothstep((dynamicScale-1) / 0.75)*0.75 + 1
  local adjustedScale = dynamicScale * scaleSetting * (0.7*smoothstep(walkScale)+0.3)
  local sizeFactor = math.min((math.min(width, height) / 400), 1)

  adjustedScale = adjustedScale / sizeFactor
  local adjustedScaleInverse = 1/adjustedScale

  if debugSettings.drawPlayer then
    local currentStyleColorSet = ui_apps_minimap_utils.getCurrentStyleColors()
    if not currentStyleColorSet then
      -- Fallback to utils colors if StyleColorSet is not available
      currentStyleColorSet = ui_apps_minimap_utils.colors
    end
    drawVehicle(pos, fwd, currentStyleColorSet.clrFocus, 1, gameplay_walk.isWalking(), layers.VEHICLE_PLAYER)
  end
  if commands.isFreeCamera() then
    --drawVehicle(camPos, cameraLook, clrOrange, 1, true, layers.VEHICLE_PLAYER)
    tmp1:set(cameraLook)

    -- Apply lookahead offset to camera position for free camera drawing
    local adjustedCamPos = vec3(camPos)
    if debugSettings.lookaheadEnabled then
      local debugSettingsData = ui_apps_minimap_minimap.getDebugSettingsData()
      local lookaheadValue = debugSettingsData.lookaheadValue[debugSettings.lookaheadValue].value
      local lookWithoutZ = vec3(cameraLook.x, cameraLook.y, 0):normalized()
      adjustedCamPos = adjustedCamPos - lookWithoutZ * lookaheadValue * scale * height/2
    end

    tmp1:setScaled(scale * 10 * dpi)
    tmp2:set(adjustedCamPos)
    tmp2:setAdd(tmp1)
    tmp1:setScaled(1.25)
    tmp3:set(adjustedCamPos)
    tmp3:setSub(tmp1)
    tmp1:set(adjustedCamPos)
    ui_apps_minimap_utils.worldToMapXYZ(tmp1,tmp1)
    ui_apps_minimap_utils.worldToMapXYZ(tmp2,tmp2)
    ui_apps_minimap_utils.worldToMapXYZ(tmp3,tmp3)

    local currentStyleColorSet = ui_apps_minimap_utils.getCurrentStyleColors()
    if not currentStyleColorSet then
      currentStyleColorSet = ui_apps_minimap_utils.colors
    end

    local strokeWidth = math.max(1, math.floor(2 * dpi))
    td:line(tmp3.x, tmp3.y, tmp2.x, tmp2.y, 0, 4*dpi, strokeWidth, strokeWidth, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, 0, layers.VEHICLE_PLAYER)
    td:line(tmp1.x, tmp1.y, tmp3.x, tmp3.y, 6*dpi, 6*dpi, strokeWidth, strokeWidth, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, currentStyleColorSet.navBg, 0, layers.VEHICLE_PLAYER)

    td:line(tmp3.x, tmp3.y, tmp2.x, tmp2.y, 0, 4*dpi, 0, 0, currentStyleColorSet.clrFocus, currentStyleColorSet.clrFocus, currentStyleColorSet.clrFocus, currentStyleColorSet.clrFocus, 0, layers.VEHICLE_PLAYER)
    td:line(tmp1.x, tmp1.y, tmp3.x, tmp3.y, 6*dpi, 6*dpi, 0, 0, currentStyleColorSet.clrFocus, currentStyleColorSet.clrFocus, currentStyleColorSet.clrFocus, currentStyleColorSet.clrFocus, 0, layers.VEHICLE_PLAYER)
  end

  -- nightmare to fix dtSim not being in sync with the map data
  lastPos2:set(lastPos)
  lastPos:set(pos)
  lastDtSim, lastVel = dtSim, vel
  return adjustedScale
end

local clrPoliceRed = color(255,0,0,255)
local clrPoliceBlue = color(0,0,255,255)
local vehIteratorCtx = {}
local ignoredTypes = {
  ['Prop'] = true,
  ['Unknown'] = true,
  ['Utility'] = true,
  ['PropTraffic'] = true,
  ['Traffic'] = true,
}
local function drawOtherVehicles(dtReal, dtSim)
  local playerVehId = be:getPlayerVehicleID(0)
  local traffic = (gameplay_traffic and gameplay_traffic.getTrafficData()) or {}
  local parking = (gameplay_parking and gameplay_parking.getParkedCarsData()) or {}
  local policeCars = (gameplay_police and gameplay_police.getPoliceVehicles()) or {}
  local canSwitch = not core_input_actionFilter.isActionBlocked("switch_next_vehicle") and not core_input_actionFilter.isActionBlocked("switch_previous_vehicle")
  for otherVId, otherVeh in activeVehiclesIterator(vehIteratorCtx) do
    if otherVId ~= playerVehId then
      local draw = false
      if debugSettings.drawParkedVehicles and parking[otherVId] then
        draw = true
      end

      local policeInfo = policeCars[otherVId]
      local isActivePoliceCar = false
      if policeInfo and policeInfo.role and policeInfo.role.targetId == playerVehId and (policeInfo.role.targetPursuitMode or 0) > 0 then
        isActivePoliceCar = true
      end

      if debugSettings.drawActivePoliceVehicles and isActivePoliceCar then
        draw = true
      end
      if debugSettings.drawTrafficVehicles and traffic[otherVId] then
        draw = true
      end
      if not draw then
        local canUse = gameplay_walk and not gameplay_walk.isVehicleBlacklisted(otherVId)
        if not debugSettings.drawUnusableVehicles and not canUse then
          goto continue
        end
        if not debugSettings.drawOtherVehicles and not canUse then
          goto continue
        end
        local model = core_vehicles.getModel(otherVeh.jbeam)
        if model and model.model and model.model.Type and ignoredTypes[model.model.Type] then
          goto continue
        end
        draw = true
      end
      if not draw then
        goto continue
      end

      pos:set(otherVeh:getPositionXYZ())
      fwd:set(otherVeh:getDirectionVectorXYZ())
      fwd.z = 0
      fwd:normalize()
      local canUse = (gameplay_walk and not gameplay_walk.isVehicleBlacklisted(otherVId)) or false
      local currentStyleColorSet = ui_apps_minimap_utils.getCurrentStyleColors()
      if not currentStyleColorSet then
        currentStyleColorSet = ui_apps_minimap_utils.colors
      end

      local vehColor = currentStyleColorSet.clrFocusMuted
      if not canUse then
        vehColor = currentStyleColorSet.grayMuted
      end

      local vehLayer = layers.VEHICLES_OTHER
      if policeInfo then
        vehColor = color(math.sin(os.clock()*5 + otherVId*0.01 )*128+128, 0, math.sin(os.clock()*5+math.pi+otherVId*0.01)*128+128, 255)
        vehLayer = layers.VEHICLES_POLICE
      elseif canUse then
        vehLayer = layers.VEHICLES_USABLE
      end

      drawVehicle(pos, fwd, vehColor, canUse and 0.8 or (policeInfo and 0.8 or 0.5), otherVeh.jbeam == "unicycle", vehLayer)
      ::continue::
    end
  end
end

-- Expose the functions
M.drawPlayer = drawPlayer
M.drawOtherVehicles = drawOtherVehicles

return M