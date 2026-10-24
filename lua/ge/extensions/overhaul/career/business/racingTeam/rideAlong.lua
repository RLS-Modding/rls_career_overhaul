-- Racing team ride-along: the player rides in the team car while AI drives, with the external camera during a proxy race.
-- Read session state, shared helpers, pre-race restoration, input/freeze, ride-along operations and hooks.
local M = {}

M.dependencies = { "overhaul_events_competitiveTrackFlow" }

local walkTarget = require('overhaul/lib/avatar/walkTarget')

local mRideAlongVehId = nil
local mVehicleFrozen = false
local mPreRaceState = nil
local mCameraNameBeforeRideAlong = nil

local function setProxyExternalCamera()
  core_camera.setByName(0, "external", true)
end

-- Switches the camera after a short delay, so the vehicle switch has settled first.
local function applyProxyExternalCameraDeferred()
  core_jobsystem.create(function(job)
    job.sleep(0.05)
    setProxyExternalCamera()
  end)
end

local function getPlayerVehId()
  local o = be:getPlayerVehicle(0)
  return o and o:getID() or nil
end

-- Serializes position and rotation for the restore; missing engine fields fall back to identity.
local function captureVehicleTransform(vehObj)
  if not vehObj then
    return nil
  end
  local pos = vehObj:getPosition()
  local rotation = vehObj:getRotation()
  local px, py, pz = pos.x, pos.y, pos.z
  local qx, qy, qz, qw = 0, 0, 0, 1
  if rotation then
    qx, qy, qz, qw = rotation.x or 0, rotation.y or 0, rotation.z or 0, rotation.w or 1
  end
  return {
    pos = { px, py, pz },
    rot = { qx, qy, qz, qw },
    levelId = getCurrentLevelIdentifier(),
    walking = gameplay_walk.isWalking() or false,
  }
end

local function unfreezePlayerVehicle(vehObj)
  if vehObj then
    core_vehicleBridge.executeAction(vehObj, "setFreeze", false)
    vehObj:queueLuaCommand("if input and input.setEnabled then input.setEnabled(true) end")
  end
  local aiRacers = overhaul_events_aiRacers
  if aiRacers and aiRacers.setPlayerFreeze then
    aiRacers.setPlayerFreeze(false)
  end
end


-- Call before teleporting the player into the team car for a business race.
function M.savePreRaceWorldState()
  local pv = be:getPlayerVehicle(0)
  local pid = getPlayerVehId()
  mPreRaceState = {
    playerVehicleId = pid,
    transform = pv and captureVehicleTransform(pv) or nil,
  }
end

-- Walking is rebuilt from the current team car; leaving a unicycle first keeps setWalkingMode from being a no-op.
local function restoreWalkingState(savedTransform)
  local p, r = savedTransform.pos, savedTransform.rot
  local walkPos = vec3(p[1], p[2], p[3])
  local walkRot = nil
  if r then
    walkRot = quat(r[1], r[2], r[3], r[4])
  end
  local pv = be:getPlayerVehicle(0)
  local alreadyUnicycle = pv and pv:getJBeamFilename() == "unicycle"
  if alreadyUnicycle then
    walkTarget.leaveWalkingModeForced(gameplay_walk)
  end
  gameplay_walk.setWalkingMode(true, walkPos, walkRot, true)
  unfreezePlayerVehicle(be:getPlayerVehicle(0))
end

-- Re-enters the saved vehicle when it differs from the current one, then puts it back at the saved pose.
local function restoreVehicleState(savedTransform, savedVehicleId)
  if savedVehicleId and be:getPlayerVehicleID(0) ~= savedVehicleId then
    local oldObj = be:getObjectByID(savedVehicleId)
    if oldObj then
      be:enterVehicle(0, oldObj)
    end
  end
  local pv = be:getPlayerVehicle(0)
  local p, r = savedTransform.pos, savedTransform.rot
  if not (pv and p and r) then
    return false
  end
  pv:setPosRot(p[1], p[2], p[3], r[1], r[2], r[3], r[4])
  unfreezePlayerVehicle(pv)
  return true
end

-- Teleports the player back to the saved transform on the same level; removed vehicles are not respawned.
function M.restorePreRaceWorldState()
  if not mPreRaceState or not mPreRaceState.transform then
    mPreRaceState = nil
    return false
  end
  local savedTransform = mPreRaceState.transform
  local curLevel = getCurrentLevelIdentifier()
  if savedTransform.levelId and curLevel and savedTransform.levelId ~= curLevel then
    mPreRaceState = nil
    return false
  end

  local restored
  if savedTransform.walking and savedTransform.pos then
    restoreWalkingState(savedTransform)
    restored = true
  else
    restored = restoreVehicleState(savedTransform, mPreRaceState.playerVehicleId)
  end
  mPreRaceState = nil
  return restored
end

function M.clearPreRaceWorldState()
  mPreRaceState = nil
end

function M.hasPreRaceWorldState()
  return mPreRaceState ~= nil
end

function M.setVehicleInputLocked(vehId, locked)
  local vid = tonumber(vehId)
  if not vid then
    return
  end
  local obj = be:getObjectByID(vid)
  if not obj then
    return
  end
  local en = locked and "false" or "true"
  obj:queueLuaCommand("if input and input.setEnabled then input.setEnabled(" .. en .. ") end")
  if locked and vid == getPlayerVehId() then
    mRideAlongVehId = vid
  end
end

function M.setVehicleFrozen(vehId, freeze)
  local obj = be:getObjectByID(vehId)
  if not obj then
    return
  end
  core_vehicleBridge.executeAction(obj, "setFreeze", freeze and true or false)
  if freeze and tonumber(vehId) == getPlayerVehId() then
    mVehicleFrozen = true
  elseif not freeze then
    mVehicleFrozen = false
  end
end


-- Once the player is in the team car, input is locked: the AI drives.
function M.beginRideAlongSession(teamCarVehId)
  local vid = tonumber(teamCarVehId)
  if not vid then
    return false
  end
  mRideAlongVehId = vid
  mCameraNameBeforeRideAlong = core_camera.getActiveCamName(0)
  M.setVehicleInputLocked(vid, true)
  applyProxyExternalCameraDeferred()
  return true
end

function M.endRideAlongSession()
  if not mRideAlongVehId then
    return
  end
  M.setVehicleInputLocked(mRideAlongVehId, false)
  if mVehicleFrozen then
    M.setVehicleFrozen(mRideAlongVehId, false)
  end
  mRideAlongVehId = nil
  mVehicleFrozen = false
  -- Walking restore sets the unicycle camera itself; restoring the vehicle camera first leaves the player seated.
  local restoringWalk = mPreRaceState and mPreRaceState.transform and mPreRaceState.transform.walking
  if restoringWalk then
    mCameraNameBeforeRideAlong = nil
    return
  end
  local prev = mCameraNameBeforeRideAlong
  mCameraNameBeforeRideAlong = nil
  if prev and prev ~= "" then
    core_camera.setByName(0, prev, false)
  else
    core_camera.resetCamera(0)
  end
end

function M.isRideAlongActive()
  return mRideAlongVehId ~= nil
end

function M.getRideAlongVehicleId()
  return mRideAlongVehId
end

local function resetSessionState()
  mRideAlongVehId = nil
  mVehicleFrozen = false
  mPreRaceState = nil
  mCameraNameBeforeRideAlong = nil
end

-- Pinned to the career lifetime: a level switch would drop us and leave racingTeam with an unresolved dependency.
function M.onInit()
  setExtensionUnloadMode(M, "manual")
  -- Restoring from the Lua reload batch fails before career is up.
  extensions.disableSerialization("overhaul_career_business_racingTeam_rideAlong")
end

function M.onVehicleSwitched(oldId, newId)
  if mRideAlongVehId and (oldId == mRideAlongVehId or newId == mRideAlongVehId) then
    M.endRideAlongSession()
  end
end

-- The race's own data decides whether a team car may ride along; no race or circuit is named here.
local function raceAllowsRideAlong(trackFlow, raceName)
  local capabilities = trackFlow.getCompetitiveRaceCapabilities and trackFlow.getCompetitiveRaceCapabilities(raceName)
  local racingTeam = capabilities and capabilities.racingTeam
  return type(racingTeam) == "table" and racingTeam.rideAlong == true
end

function M.onFreeroamSessionStarted(data)
  if type(data) ~= "table" then
    return
  end
  local trackFlow = overhaul_events_competitiveTrackFlow
  if trackFlow and trackFlow.isRacingTeamProxyRaceSessionActive() and raceAllowsRideAlong(trackFlow, data.raceName) then
    M.beginRideAlongSession(data.subjectID)
  end
end

function M.onFreeroamSessionExiting()
  M.endRideAlongSession()
  M.restorePreRaceWorldState()
end

function M.onOverhaulActive(active)
  if not active and mRideAlongVehId then
    M.setVehicleInputLocked(mRideAlongVehId, false)
    if mVehicleFrozen then
      M.setVehicleFrozen(mRideAlongVehId, false)
    end
  end
  resetSessionState()
end

function M.onClientEndMission()
  resetSessionState()
end

return M
