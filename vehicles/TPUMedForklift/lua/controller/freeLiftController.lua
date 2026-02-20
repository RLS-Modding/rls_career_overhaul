-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
--Mandatory controller parameters
M.type = "auxiliary"
M.relevantDevice = nil
-----

local htmlTexture = require("htmlTexture")

local max = math.max

local sensorBeams = {front = {}, center = {}, rear = {}}
local stressSmoothers = {front = nil, center = nil, rear = nil}

local massFront = 0
local massCenter = 0
local massRear = 0
local tareOffsetFront = 0
local tareOffsetCenter = 0
local tareOffsetRear = 0

local doTare = false
local tareTimer = 0

local updateTimer = 0
local updateThreshold = 1 / 5

local function setTare()
  doTare = true
  tareTimer = 3
end

local function updateGFX(dt)
  local stressSumFront = 0
  local stressSumCenter = 0
  local stressSumRear = 0

  for _,cid in ipairs(sensorBeams.front) do
    stressSumFront = stressSumFront + obj:getBeamStress(cid)
  end

  for _,cid in ipairs(sensorBeams.center) do
    stressSumCenter = stressSumCenter + obj:getBeamStress(cid)
  end

  for _,cid in ipairs(sensorBeams.rear) do
    stressSumRear = stressSumRear + obj:getBeamStress(cid)
  end

  local gravity = obj:getGravity()
  local invGravity = gravity ~= 0 and 1 / obj:getGravity() or 1
  massFront = stressSmoothers.front:get(stressSumFront * invGravity, dt)
  massCenter = stressSmoothers.center:get(stressSumCenter * invGravity, dt)
  massRear = stressSmoothers.rear:get(stressSumRear * invGravity, dt)

  local massFrontTare = 0
  local massCenterTare = 0
  local massRearTare = 0

  if not doTare then
    massFrontTare = massFront - tareOffsetFront
    massCenterTare = massCenter - tareOffsetCenter
    massRearTare = massRear - tareOffsetRear
  else
    tareTimer = max(tareTimer - dt, 0)
    if tareTimer <= 0 then
      tareOffsetFront = massFront
      tareOffsetCenter = massCenter
      tareOffsetRear = massRear
      doTare = false
    end
  end

  updateTimer = updateTimer + dt
  if updateTimer > updateThreshold then
    local data = {front = massFrontTare, center = massCenterTare, rear = massRearTare, doTare = doTare}
    htmlTexture.call("@weightpad_display", "updateData", data)
    updateTimer = 0
  end
end

local function init(jbeamData)
  doTare = true
  tareTimer = 6
  updateTimer = 1
  local inRate = 3
  local outRate = 1.2
  stressSmoothers = {front = newTemporalSmoothingNonLinear(inRate, outRate), center = newTemporalSmoothingNonLinear(inRate, outRate), rear = newTemporalSmoothingNonLinear(inRate, outRate)}
  sensorBeams = {front = {}, center = {}, rear = {}}

  massFront = 0
  massCenter = 0
  massRear = 0
  tareOffsetFront = 0
  tareOffsetCenter = 0
  tareOffsetRear= 0

  for cid,beam in pairs(v.data.beams) do
    if beam.isSensorBeamCenter then
      table.insert(sensorBeams.center, cid)
    elseif beam.isSensorBeamFront then
      table.insert(sensorBeams.front, cid)
    elseif beam.isSensorBeamRear then
      table.insert(sensorBeams.rear, cid)
    end
  end

  htmlTexture.create("@weightpad_display", "local://local/vehicles/weightpad/weightpad_display.html", 512, 128, 5)
end


M.init = init
M.updateGFX = updateGFX
M.setTare = setTare

return M