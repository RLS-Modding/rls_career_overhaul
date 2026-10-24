-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- GE-callable API: enableWheelData(), disableWheelData().
-- Owns the wheel telemetry stream while enabled; read smoothing, payload updates, then the toggle API.
-- Fork of stock lua/vehicle/extensions/advancedwheeldebug.lua (BeamNG 0.40).
local M = {}
local geCallback = require('vehicle/overhaul/geCallback')

local acos = math.acos
local deg = math.deg

local enabledVehicleId

local smoothedData = {}
local updateTimer = 0
local updateRate = 0.1 -- 10Hz update rate
local smoothingTime = -1 / (60 * math.log(0.9))

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function updateGFX(dt)
  local vehId = enabledVehicleId
  if not vehId then
    return
  end

  if not v or not v.data or not v.data.wheels or not wheels then
    return
  end

  updateTimer = updateTimer + math.max(0, dt or 0)
  if updateTimer + 1e-9 < updateRate then return end
  local elapsed = math.floor((updateTimer + 1e-9) / updateRate) * updateRate
  updateTimer = math.max(0, updateTimer - elapsed)
  local smoothingFactor = 1 - math.exp(-elapsed / smoothingTime)

  local vehForward = obj:getDirectionVector()
  local vehRight = obj:getDirectionVectorRight()
  if not vehRight then
    local vehUp = obj:getDirectionVectorUp()
    if not vehUp then
      vehUp = vec3(0, 0, 1)
    end
    vehRight = vehForward:cross(vehUp)
    vehRight:normalize()
  end

  local surfaceUp = vec3()
  local count = 0

  for i = 0, wheels.wheelRotatorCount - 1 do
    local wheel = wheels.wheelRotators[i]
    local nodeId = wheel.lastTreadContactNode
    if nodeId then
      local pos = obj:getNodePosition(nodeId) + obj:getPosition()
      local normal = mapmgr.surfaceNormalBelow(pos, 0.1)
      surfaceUp:setAdd(normal)
      count = count + 1
    end
  end

  if count == 0 then
    -- If no contact, we might want to keep previous values or return. 
    -- Returning here means we just don't update the smoothed data this frame.
    return
  end

  surfaceUp:setScaled(1 / count)
  local surfaceRight = vehForward:cross(surfaceUp)
  surfaceRight:normalize()
  local surfaceForward = surfaceUp:cross(surfaceRight)
  surfaceForward:normalize()

  -- Calculate raw data for this frame
  for _, wd in pairs(v.data.wheels) do
    local name = wd.name

    -- Initialize smoothed data for this wheel if missing
    if not smoothedData[name] then
      smoothedData[name] = {
        name = name,
        camber = 0,
        toe = 0,
        caster = 0,
        sai = 0
      }
    end

    local currentData = {}

    if wd.steerAxisUp and wd.steerAxisDown then
      local casterSign = -obj:nodeVecCos(wd.steerAxisUp, wd.steerAxisDown, surfaceForward)
      currentData.caster =
        deg(acos(obj:nodeVecPlanarCos(wd.steerAxisUp, wd.steerAxisDown, surfaceUp, surfaceForward))) * sign(casterSign)
      currentData.sai = deg(acos(obj:nodeVecPlanarCos(wd.steerAxisUp, wd.steerAxisDown, surfaceUp, surfaceRight)))
    end

    currentData.camber = (90 - deg(acos(obj:nodeVecPlanarCos(wd.node2, wd.node1, surfaceUp, surfaceRight))))
    local toeSign = obj:nodeVecCos(wd.node1, wd.node2, vehForward)
    currentData.toe = deg(acos(obj:nodeVecPlanarCos(wd.node1, wd.node2, vehRight, vehForward)))
    if currentData.toe > 90 then
      currentData.toe = (180 - currentData.toe) * sign(toeSign)
    else
      currentData.toe = currentData.toe * sign(toeSign)
    end

    -- Sanitize inputs
    if isnan(currentData.toe) or isinf(currentData.toe) then
      currentData.toe = 0
    end
    if isnan(currentData.camber) or isinf(currentData.camber) then
      currentData.camber = 0
    end
    if currentData.caster and (isnan(currentData.caster) or isinf(currentData.caster)) then
      currentData.caster = 0
    end
    if currentData.sai and (isnan(currentData.sai) or isinf(currentData.sai)) then
      currentData.sai = 0
    end

    -- Apply smoothing
    smoothedData[name].camber = lerp(smoothedData[name].camber, currentData.camber, smoothingFactor)
    smoothedData[name].toe = lerp(smoothedData[name].toe, currentData.toe, smoothingFactor)

    if currentData.caster then
      smoothedData[name].caster = lerp(smoothedData[name].caster, currentData.caster, smoothingFactor)
    end
    if currentData.sai then
      smoothedData[name].sai = lerp(smoothedData[name].sai, currentData.sai, smoothingFactor)
    end
  end

  local dataToSend = {}
  for _, wheelData in pairs(smoothedData) do
    table.insert(dataToSend, wheelData)
  end

  -- Escape backslashes first so quote escaping survives the GE string.
  obj:queueGameEngineLua(geCallback.command("onVehicleWheelDataUpdate", vehId .. ", '" .. jsonEncode(dataToSend):gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"))
end

local function enableWheelData()
  enabledVehicleId = obj:getID()
end

local function disableWheelData()
  enabledVehicleId = nil
end

M.updateGFX = updateGFX
M.enableWheelData = enableWheelData
M.disableWheelData = disableWheelData

return M
