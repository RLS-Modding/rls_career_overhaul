-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/ui/apps/minimap/vehicles.lua (BeamNG 0.40).
-- Draws the minimap's vehicle layer: the player's car or walker, and the other vehicles around them.
-- The minimap calls setMinimapState each frame, then drawPlayer and drawOtherVehicles.

local M = {}

local layers = require("ui/apps/minimap/layers")

-- Config ------------------------------------------------------------------------------------------

local localFwd = vec3(0, 1, 0)
local scaleSetting = 0.5 -- px/m
local ignoredTypes = {
  ['Prop'] = true,
  ['Unknown'] = true,
  ['Utility'] = true,
  ['PropTraffic'] = true,
  ['Traffic'] = true,
}
local emptyVehicleData = {}

-- State -------------------------------------------------------------------------------------------

-- Player motion from the previous frame, for the speed that grows the marker.
local lastPos, lastPos2, pos, fwd = vec3(), vec3(), vec3(), vec3()
local lastDtSim, lastVel = 0, 0
local hasLastPosition = false
local velSmoother = newTemporalSmoothing(0.25, 0.5, nil, 1)
local walkSmoother = newTemporalSmoothing(2, 1, nil, 1)
local rot = quat()
-- Scratch vectors shared by the marker shapes; each shape sets them before reading them.
local tmp1, tmp2, tmp3 = vec3(), vec3(), vec3()
local adjustedCamPos, freeCamLookWithoutZ = vec3(), vec3()

-- Set by setMinimapState each frame from the minimap.
local width, height
local camPos, scale
local textureDraw, debugSettings, cameraLook, styleColorSet
local worldToMapXX, worldToMapXY, worldToMapYX, worldToMapYY = 0, 0, 0, 0
local worldToMapXOffset, worldToMapYOffset = 0, 0
local dpi = 1

-- Marker shapes -----------------------------------------------------------------------------------

-- Stock 0.40.1 builds both marker shapes in TextureDraw using the cached map transform.
local function drawVehicle(position, forward, color, size, asCircle, layer)
  textureDraw:vehicleMarker(position.x, position.y, forward.x, forward.y, color, styleColorSet.navBg,
    size, not not asCircle, scale, dpi, worldToMapXX, worldToMapXY, worldToMapYX, worldToMapYY,
    worldToMapXOffset, worldToMapYOffset, layer or layers.VEHICLES_OTHER)
end

-- Player ------------------------------------------------------------------------------------------

-- Puts the player's position and heading into pos and fwd; false when there is no vehicle to follow.
local function readPlayerPose(isWalking)
  if isWalking then
    pos:set(gameplay_walk.getPosXYZ())
    rot:set(gameplay_walk.getRotXYZW())
    fwd:setRotate(rot, localFwd)
    fwd.z = 0
    fwd:normalize()
    return true
  end

  local vehId = be:getPlayerVehicleID(0)
  if not vehId then return false end
  local vehicleData = map.objects[vehId]
  if not vehicleData then return false end
  pos:set(vehicleData.pos)
  fwd:set(vehicleData.dirVec.x, vehicleData.dirVec.y, 0)
  fwd:normalize()
  return true
end

-- Speed in m/s from the last two frames; a frame without time to measure keeps the last speed.
local function playerSpeed(dtSim)
  return (hasLastPosition and lastDtSim > 0.0001) and (lastPos:distance(lastPos2) / lastDtSim) or lastVel
end

-- Marker scale for this frame: grows with speed, shrinks while walking, and fits small minimaps.
local function playerMarkerScale(dtReal, vel, isWalking)
  local dynamicScale = clamp(velSmoother:get(vel > 10 and 3.0 or 1, dtReal), 1, 1.75)
  local walkScale = walkSmoother:get(isWalking and 0 or 1, dtReal)
  dynamicScale = smoothstep((dynamicScale - 1) / 0.75) * 0.75 + 1
  local adjustedScale = dynamicScale * scaleSetting * (0.7 * smoothstep(walkScale) + 0.3)
  local sizeFactor = math.min((math.min(width, height) / 400), 1)
  return adjustedScale / sizeFactor
end

-- The free camera's position, pulled back along its look when lookahead is on.
local function lookaheadCameraPos()
  adjustedCamPos:set(camPos)
  if not debugSettings.lookaheadEnabled then return adjustedCamPos end
  local lookaheadValue = ui_apps_minimap_minimap.getDebugSettingsData().lookaheadValue[debugSettings.lookaheadValue].value
  freeCamLookWithoutZ:set(cameraLook.x, cameraLook.y, 0)
  freeCamLookWithoutZ:normalize()
  freeCamLookWithoutZ:setScaled(lookaheadValue * scale * height / 2)
  adjustedCamPos:setSub(freeCamLookWithoutZ)
  return adjustedCamPos
end

-- Free camera: a line from behind the camera out to its look tip, drawn as an outline pass, then a fill pass.
local function drawFreeCameraMarker()
  tmp1:set(cameraLook)
  local cameraPos = lookaheadCameraPos()
  tmp1:setScaled(scale * 10 * dpi)
  tmp2:set(cameraPos)
  tmp2:setAdd(tmp1)
  tmp1:setScaled(1.25)
  tmp3:set(cameraPos)
  tmp3:setSub(tmp1)
  tmp1:set(cameraPos)
  ui_apps_minimap_utils.worldToMapXYZ(tmp1, tmp1)
  ui_apps_minimap_utils.worldToMapXYZ(tmp2, tmp2)
  ui_apps_minimap_utils.worldToMapXYZ(tmp3, tmp3)

  local navBg, clrFocus = styleColorSet.navBg, styleColorSet.clrFocus
  local strokeWidth = math.max(1, math.floor(2 * dpi))
  textureDraw:line(tmp3.x, tmp3.y, tmp2.x, tmp2.y, 0, 4 * dpi, strokeWidth, strokeWidth, navBg, navBg, navBg, navBg, 0, layers.VEHICLE_PLAYER)
  textureDraw:line(tmp1.x, tmp1.y, tmp3.x, tmp3.y, 6 * dpi, 6 * dpi, strokeWidth, strokeWidth, navBg, navBg, navBg, navBg, 0, layers.VEHICLE_PLAYER)

  textureDraw:line(tmp3.x, tmp3.y, tmp2.x, tmp2.y, 0, 4 * dpi, 0, 0, clrFocus, clrFocus, clrFocus, clrFocus, 0, layers.VEHICLE_PLAYER)
  textureDraw:line(tmp1.x, tmp1.y, tmp3.x, tmp3.y, 6 * dpi, 6 * dpi, 0, 0, clrFocus, clrFocus, clrFocus, clrFocus, 0, layers.VEHICLE_PLAYER)
end

local function drawPlayer(dtReal, dtSim)
  local isWalking = gameplay_walk and gameplay_walk.isWalking()
  if not readPlayerPose(isWalking) then return end

  local vel = playerSpeed(dtSim)
  local adjustedScale = playerMarkerScale(dtReal, vel, isWalking)
  if debugSettings.drawPlayer then
    drawVehicle(pos, fwd, styleColorSet.clrFocus, 1, isWalking, layers.VEHICLE_PLAYER)
  end
  if commands.isFreeCamera() then drawFreeCameraMarker() end

  -- nightmare to fix dtSim not being in sync with the map data
  if hasLastPosition then
    lastPos2:set(lastPos)
    lastPos:set(pos)
  else
    lastPos:set(pos)
    lastPos2:set(pos)
    hasLastPosition = true
  end
  lastDtSim, lastVel = dtSim, vel
  return adjustedScale
end

-- Other vehicles ----------------------------------------------------------------------------------

-- Per-frame lookups for the other-vehicle filter, refilled at the start of each draw.
local otherFrame = {}
local vehIteratorCtx = {}
local ignoredModels = {}
local function clearModelCache()
  ignoredModels = {}
end
local function isIgnoredModel(jbeam)
  if not jbeam then return false end
  local ignored = ignoredModels[jbeam]
  if ignored == nil then
    local model = core_vehicles.getModel(jbeam)
    local modelType = model and model.model and model.model.Type
    -- A model can be queried before its metadata has finished loading.
    if type(modelType) ~= "string" or modelType == "" then return false end
    ignored = not not ignoredTypes[modelType]
    ignoredModels[jbeam] = ignored
  end
  return ignored
end

-- True when the vehicle is a police car pursuing the player.
local function isActivePursuit(policeInfo, playerVehId)
  local role = policeInfo and policeInfo.role
  return (role and role.targetId == playerVehId and (role.targetPursuitMode or 0) > 0) or false
end

-- Parked, traffic and active-pursuit cars are drawn whatever their usability.
local function isAlwaysDrawnOtherVehicle(otherVId)
  if debugSettings.drawParkedVehicles and otherFrame.parking[otherVId] then return true end
  if debugSettings.drawActivePoliceVehicles and isActivePursuit(otherFrame.policeCars[otherVId], otherFrame.playerVehId) then
    return true
  end
  return (debugSettings.drawTrafficVehicles and otherFrame.traffic[otherVId]) and true or false
end

-- A car the player can drive; a blacklisted car cannot be used.
local function isUsableOtherVehicle(otherVId)
  return (gameplay_walk and not gameplay_walk.isVehicleBlacklisted(otherVId)) or false
end

-- Whether a vehicle is drawn this frame, and its usability when that check ran.
local function otherVehicleFilter(otherVId, otherVeh)
  if isAlwaysDrawnOtherVehicle(otherVId) then return true, nil end

  local canUse = isUsableOtherVehicle(otherVId)
  if not debugSettings.drawUnusableVehicles and not canUse then return false end
  if not debugSettings.drawOtherVehicles and not canUse then return false end
  if isIgnoredModel(otherVeh.jbeam) then return false end
  return true, canUse
end

local function drawOtherVehicle(otherVId, otherVeh, canUse, policeInfo)
  fwd:set(otherVeh:getDirectionVectorXYZ())
  fwd.z = 0
  fwd:normalize()
  -- Forced vehicles skipped the usability check above, so it runs now.
  if canUse == nil then canUse = not gameplay_walk or not gameplay_walk.isVehicleBlacklisted(otherVId) end
  if not gameplay_walk then canUse = true end

  local vehColor = styleColorSet.clrFocusMuted
  if not canUse then vehColor = styleColorSet.grayMuted end

  local vehLayer = layers.VEHICLES_OTHER
  if policeInfo then
    vehColor = color(math.sin(otherFrame.policePulseTime + otherVId * 0.01) * 128 + 128, 0, math.sin(otherFrame.policePulseTime + math.pi + otherVId * 0.01) * 128 + 128, 255)
    vehLayer = layers.VEHICLES_POLICE
  elseif canUse then
    vehLayer = layers.VEHICLES_USABLE
  end

  drawVehicle(pos, fwd, vehColor, canUse and 0.8 or (policeInfo and 0.8 or 0.5), otherVeh.jbeam == "unicycle", vehLayer)
end

local function drawOtherVehicles(dtReal, dtSim)
  otherFrame.playerVehId = be:getPlayerVehicleID(0)
  otherFrame.traffic = (debugSettings.drawTrafficVehicles and gameplay_traffic and gameplay_traffic.getTrafficData()) or emptyVehicleData
  otherFrame.parking = (debugSettings.drawParkedVehicles and overhaul_integration_services_parking and overhaul_integration_services_parking.getParkedCarsData()) or emptyVehicleData
  otherFrame.policeCars = (overhaul_integration_services_police and overhaul_integration_services_police.getPoliceVehicles()) or emptyVehicleData
  otherFrame.policePulseTime = os.clock() * 5
  local cullRadius = math.sqrt(width * width + height * height) * scale * 0.5 + 16 * scale * dpi
  for otherVId, otherVeh in activeVehiclesIterator(vehIteratorCtx) do
    if otherVId ~= otherFrame.playerVehId then
      pos:set(otherVeh:getPositionXYZ())
      if math.abs(pos.x - camPos.x) <= cullRadius and math.abs(pos.y - camPos.y) <= cullRadius then
        local draw, canUse = otherVehicleFilter(otherVId, otherVeh)
        if draw then drawOtherVehicle(otherVId, otherVeh, canUse, otherFrame.policeCars[otherVId]) end
      end
    end
  end
end

-- Public API --------------------------------------------------------------------------------------

-- Takes the minimap's settings for this frame. The stock call's centre, rotation and inverse-scale
-- arguments are unused: the shared utils provide the current map transform.
local function setMinimapState(viewWidth, viewHeight, _, _, cameraPos, _, _, mapScale, _, textureDrawObj, debugSettingsObj,
    cameraLookObj, dpiValue)
  width = viewWidth
  height = viewHeight
  camPos = cameraPos
  scale = mapScale
  textureDraw = textureDrawObj
  debugSettings = debugSettingsObj
  cameraLook = cameraLookObj
  dpi = (dpiValue or 1) * (globalDpi or 1)
  styleColorSet = ui_apps_minimap_utils.getCurrentStyleColors() or ui_apps_minimap_utils.colors
  worldToMapXX, worldToMapXY, worldToMapYX, worldToMapYY, worldToMapXOffset, worldToMapYOffset =
    ui_apps_minimap_utils.getWorldToMapTransform()
end

M.setMinimapState = setMinimapState
M.drawPlayer = drawPlayer
M.drawOtherVehicles = drawOtherVehicles
M.clearModelCache = clearModelCache

return M
