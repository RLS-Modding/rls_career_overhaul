-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/core/cameraModes/unicycle.lua (BeamNG 0.40).

-- Overhaul's walking camera (bob, sway, entry/exit offsets) on the game's unicycle camera class.
local M = {}

M.dependencies = {"overhaul_shell_patches"}

local PATCH_ID = "unicycleCamera"

local min, max, abs = math.min, math.max, math.abs
local sin, cos, exp = math.sin, math.cos, math.exp

-- playerController: walk 1.8 m/s, sprint 5 m/s
local bobScale = 0.5
local walkSpeedMetersPerSecond = 1.8
local sprintSpeedMetersPerSecond = 5.0
local humanHeightMeters = 1.6
local downVec = vec3(0, 0, -1)
local groundProbe = vec3()

local function smoothApproach(current, target, dt, rate)
  return current + (target - current) * (1 - exp(-dt * rate))
end

local function isBobEnabled()
  local s = rawget(_G, "overhaul_shell_settings")
  if s and s.getSetting then
    return s.getSetting("realisticWalkingCamera") ~= false
  end
  return true
end

local function isRadialMenuOpen()
  return core_quickAccess and core_quickAccess.isEnabled() or false
end

local function rotateEuler(x, y, z, q)
  q = q or quat()
  q = quatFromEuler(0, z, 0) * q
  q = quatFromEuler(0, 0, x) * q
  q = quatFromEuler(y, 0, 0) * q
  return q
end

local function castRayLocation(origin, target)
  local rayDirection = target - origin
  local rayLengthMeters = rayDirection:length()
  local hitDistanceMeters = castRayStatic(origin, rayDirection, rayLengthMeters)
  if hitDistanceMeters >= rayLengthMeters then return end
  return origin + (rayDirection:normalized() * hitDistanceMeters)
end

local function getEyePosition(pos)
  local resultGround = castRayLocation(pos + vec3(0, 0, humanHeightMeters * 0.45), pos + vec3(0, 0, -5))
  if resultGround then
    return resultGround + vec3(0, 0, humanHeightMeters)
  end
  return pos
end

local function getRotVecFromFrontUp(front, up)
  local initialLookDir = quatFromDir(front, up or vec3(0, 0, 1))
  local rotEuler = initialLookDir:toEulerYXZ()
  local pitch = clamp(math.deg(rotEuler.y), -89.9, 89.9)
  return vec3(math.deg(rotEuler.x), 180 - pitch, 0)
end

local function initBobState(self)
  self.bobPhase = 0
  self.bobT = 0
  self.bobPhaseVec = vec3(math.random(), math.random(), math.random()) * (2 * math.pi)
  self.walkAmtSmooth = 0
  self.sprintAmtSmooth = 0
  self.climbAmtSmooth = 0
  self.groundedBlend = 1
  self.wasGrounded = true
  self.landDip = 0
  self.jumpPitch = 0
  self.prevVz = 0
  self.prevGroundZ = nil
end

local function setCustomData(self, customData)
  customData = customData or {}
  if customData.pos then
    self.pos = getEyePosition(customData.pos)
  end
  if customData.front then
    self.rotVec = getRotVecFromFrontUp(customData.front, customData.up)
  end
end

local function setScriptedTransition(self, data)
  self.scriptedTransition = data
end

local function update(self, data)
  if self.bobPhase == nil then initBobState(self) end
  local dt = data.dtSim
  -- Near-zero dtSim (menu open / hitch) would blow up climbRate and bob.
  local dtSafe = max(dt, 1 / 120)
  local radialOpen = isRadialMenuOpen()
  if not self.rotVec then
    local veh = data.veh
    self:setCustomData({pos = data.pos, front = veh:getDirectionVector(), up = veh:getDirectionVectorUp()})
  end

  local zoomValue = self.zoomSmoother:get(data.unicycleZoom or 0, dtSafe)
  data.res.fov = zoomValue * 27 + (1 - zoomValue) * 55

  -- Relative mouse/stick look is ignored while the radial menu is open.
  local lookScale = (1 - zoomValue * 0.88) * 20 * dtSafe
  local rdx = lookScale * (MoveManager.yawRight - MoveManager.yawLeft)
  local rdyNotMouse = lookScale * (MoveManager.pitchUp - MoveManager.pitchDown)
  local rdy = rdyNotMouse
  if not radialOpen then
    rdx = MoveManager.yawRelative + rdx
    rdy = MoveManager.pitchRelative + rdyNotMouse
  end
  if data.openxrSessionRunning and self.openXRsnapTurnUnicycle then
    local mustTurn = false
    self.lastSnapTurn = self.lastSnapTurn or 0
    if rdx ~= 0 and (self.rdxLast or 0) == 0 then
      self.lastSnapTurn = os.clock()
      mustTurn = true
    end
    if sign(rdx) ~= sign(self.rdxLast or 0) then
      self.lastSnapTurn = os.clock()
      mustTurn = true
    end
    if rdx ~= 0 then
      local snapTurnPeriod = 0.4
      if os.clock() - self.lastSnapTurn > snapTurnPeriod then
        self.lastSnapTurn = self.lastSnapTurn + snapTurnPeriod
        mustTurn = true
      end
    end
    if mustTurn then
      self.rotVec.x = self.rotVec.x + sign(rdx) * self.openXRsnapTurnUnicycleDegrees
    end
    self.rdxLast = rdx
  else
    self.rotVec = self.rotVec + (dt > 0 and 7 or 0) * vec3(rdx, rdy, 0)
    self.rotVec.y = clamp(self.rotVec.y, 180 - 89.9, 180 + 89.9)
  end
  if data.openxrSessionRunning then
    self.rotVec.y = 180
    if rdyNotMouse < -0.15 and (self.rdyNotMouseLast or 0) >= -0.15 then
      self.rotVec.x = self.rotVec.x + 180
    end
    self.rdyNotMouseLast = rdyNotMouse
  end

  local rot = rotateEuler(-math.rad(self.rotVec.x), -math.rad(self.rotVec.y), math.rad(self.rotVec.z))
  local controlRot = rot

  local ctxId = core_camera.getContextIdForPlayer(data.player)
  local camNodeID = core_camera.getDriverData(data.veh, ctxId)
  local nodePos = vec3(data.veh:getNodePosition(camNodeID or 0))
  self.pos = data.pos + nodePos

  local bobUp, swayPitch, swayRoll, swayYaw = 0, 0, 0, 0
  -- Bob decays while the radial is open or bob is disabled, so re-enabling is clean.
  if not data.openxrSessionRunning and dt > 0 then
    if radialOpen or not isBobEnabled() then
      self.walkAmtSmooth = smoothApproach(self.walkAmtSmooth, 0, dtSafe, 20)
      self.sprintAmtSmooth = smoothApproach(self.sprintAmtSmooth, 0, dtSafe, 20)
      self.climbAmtSmooth = smoothApproach(self.climbAmtSmooth, 0, dtSafe, 20)
      self.landDip = self.landDip * exp(-dtSafe * 16)
      self.jumpPitch = smoothApproach(self.jumpPitch, 0, dtSafe, 20)
      self.prevGroundZ = nil
    else
      local vel = data.veh:getVelocity()
      local horizSpeed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
      local vz = vel.z

      groundProbe:set(self.pos.x, self.pos.y, self.pos.z)
      local groundDist = castRayStatic(groundProbe, downVec, humanHeightMeters + 0.8)
      local nearGround = groundDist < (humanHeightMeters + 0.35)
      local grounded = nearGround and vz < 2.2
      self.groundedBlend = smoothApproach(self.groundedBlend, grounded and 1 or 0, dtSafe, grounded and 14 or 6)

      local groundZ = self.pos.z - groundDist
      local climbRate = 0
      if self.prevGroundZ and grounded then
        climbRate = clamp((groundZ - self.prevGroundZ) / dtSafe, -3, 3)
      end
      if grounded then
        self.prevGroundZ = groundZ
      else
        self.prevGroundZ = nil
      end

      if grounded and not self.wasGrounded then
        local impact = min(max(-self.prevVz, 0) / 8, 1)
        self.landDip = max(self.landDip, 0.004 + 0.010 * impact)
      end
      self.wasGrounded = grounded
      self.prevVz = vz
      self.landDip = self.landDip * exp(-dtSafe * 16)

      local jumpPitchTarget = 0
      if self.groundedBlend < 0.85 then
        jumpPitchTarget = clamp(vz * 0.004, -0.015, 0.015)
      end
      self.jumpPitch = smoothApproach(self.jumpPitch, jumpPitchTarget, dtSafe, 14)
      self.jumpPitch = self.jumpPitch - self.landDip * 0.25

      local walkTarget, sprintTarget = 0, 0
      if horizSpeed > 0.15 then
        walkTarget = min(horizSpeed / walkSpeedMetersPerSecond, 1)
        sprintTarget = clamp((horizSpeed - walkSpeedMetersPerSecond) / (sprintSpeedMetersPerSecond - walkSpeedMetersPerSecond), 0, 1)
      end
      walkTarget = walkTarget * self.groundedBlend
      sprintTarget = sprintTarget * self.groundedBlend
      self.walkAmtSmooth = smoothApproach(self.walkAmtSmooth, walkTarget, dtSafe, 10)
      self.sprintAmtSmooth = smoothApproach(self.sprintAmtSmooth, sprintTarget, dtSafe, 8)

      local walkAmt = self.walkAmtSmooth
      local sprintAmt = self.sprintAmtSmooth
      local moveAmt = max(walkAmt, sprintAmt)

      -- Rising ground underfoot while moving: stairs or a steep rise.
      local climbTarget = 0
      if moveAmt > 0.2 and climbRate > 0.18 then
        climbTarget = clamp((climbRate - 0.18) / 0.75, 0, 1) * self.groundedBlend
      end
      self.climbAmtSmooth = smoothApproach(self.climbAmtSmooth, climbTarget, dtSafe, 7)
      local climbAmt = self.climbAmtSmooth

      local bobRate = (5.8 + 0.9 * sprintAmt) * moveAmt * (1 - 0.40 * climbAmt)
      self.bobT = self.bobT + dtSafe
      self.bobPhase = self.bobPhase + dtSafe * bobRate

      local foot = sin(self.bobPhase)
      local plant = abs(foot)
      plant = plant * plant
      local stepLift = 0.5 * (1 - cos(self.bobPhase * 2))

      local stepAmp = bobScale * (0.034 * walkAmt + 0.022 * sprintAmt)
      bobUp = (stepLift * stepAmp * 0.55 - plant * stepAmp * 0.45) * self.groundedBlend
      if climbAmt > 0.01 then
        local stairAmp = bobScale * 0.055 * climbAmt * moveAmt
        bobUp = bobUp + stepLift * stairAmp * 0.85 - plant * stairAmp * 0.65
      end
      bobUp = bobUp - self.landDip

      local var = bobScale * (1 - 0.82 * sprintAmt) * (0.4 + 0.6 * self.groundedBlend)
      local t, ph = self.bobT, self.bobPhaseVec
      swayPitch = var * 0.014 * walkAmt * sin(self.bobPhase * 2)
        + var * 0.003 * (1 - sprintAmt) * sin(0.7 * t + ph.y)
        + self.jumpPitch
        + climbAmt * (0.018 + 0.022 * plant)
      swayRoll = var * 0.020 * walkAmt * foot * (1 - 0.65 * sprintAmt)
        + var * 0.004 * (1 - sprintAmt) * sin(0.45 * t + ph.z)
        + climbAmt * 0.012 * foot * moveAmt
      swayYaw = var * 0.006 * walkAmt * sin(self.bobPhase + 0.8) * (1 - 0.75 * sprintAmt)
        + var * 0.003 * (1 - sprintAmt) * sin(0.55 * t + ph.x)

      local still = (1 - moveAmt) * bobScale * self.groundedBlend
      if still > 0.01 then
        local breath = sin(t * 1.15 + ph.x)
        bobUp = bobUp + still * 0.010 * breath
        swayPitch = swayPitch + still * 0.008 * breath
        swayYaw = swayYaw + still * 0.006 * sin(t * 0.55 + ph.z)
      end

      rot = rot * quatFromEuler(swayPitch, swayRoll, swayYaw)
    end
  end

  local transitionOffset = vec3(0, 0, bobUp)
  local scripted = self.scriptedTransition
  if scripted and not data.openxrSessionRunning then
    local localOffset = vec3(scripted.side or 0, scripted.forward or 0, scripted.z or 0)
    transitionOffset:setAdd(rot * localOffset)
    transitionOffset:setAdd(vec3(scripted.worldX or 0, scripted.worldY or 0, scripted.worldZ or 0))
    rot = rot * quatFromEuler(scripted.pitch or 0, scripted.roll or 0, scripted.yaw or 0)
  end
  data.res.pos:set(self.pos.x + transitionOffset.x, self.pos.y + transitionOffset.y, self.pos.z + transitionOffset.z)
  data.res.rot = rot

  -- The player controller steers by the unswayed camera rotation.
  data.veh:queueLuaCommand("controller.getControllerSafe('playerController').setCameraControlData(" .. serialize({cameraRotation = controlRot}) .. ")")
  return true
end

local methods = {
  update = update,
  setCustomData = setCustomData,
  setScriptedTransition = setScriptedTransition,
}

local cameraClass
local originals

local function getCameraClass()
  local constructor = require("core/cameraModes/unicycle")
  if type(constructor) ~= "function" then return nil end
  for index = 1, math.huge do
    local name, value = debug.getupvalue(constructor, index)
    if not name then break end
    if type(value) == "table" and value.__index == value and type(value.update) == "function" then return value end
  end
end

local function uninstall()
  if cameraClass and originals then
    for key, fn in pairs(methods) do
      if cameraClass[key] == fn then cameraClass[key] = originals[key] end
    end
  end
  cameraClass, originals = nil, nil
end

local function install()
  uninstall()
  local class = getCameraClass()
  if not class then error("unicycle camera class not found") end
  originals = {}
  for key, fn in pairs(methods) do
    originals[key] = class[key]
    class[key] = fn
  end
  cameraClass = class
end

local function refresh()
  local class = getCameraClass()
  if class == cameraClass and class.update == update then return end
  install()
end

M.isPatched = function() return cameraClass ~= nil and cameraClass.update == update end

M.onExtensionLoaded = function()
  overhaul_shell_patches.register(PATCH_ID, install, uninstall, refresh)
end

M.onExtensionUnloaded = function()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

return M
