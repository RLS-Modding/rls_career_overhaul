-- Owns spectator camera entry, cycling, and restoration.
-- drag/runner.lua owns the spectating lifetime; drag/spectatorHud.lua owns spectator-specific HUD changes.
local M = {}
local hud = require('overhaul/events/motorsportEvents/drag/spectatorHud')
local watching, previousCamera = false, nil
local trackingTarget, originalPosition, originalRotation
local cameras, cameraIndex, previousPosition, previousRotation = {}, 0, nil, nil
local previousFov, baseFov, zoomFov
local leaderBlend = 0
local followDistance, rolloutElapsed, previousPhase = nil, 0, nil
local idleView, rolloutPosition, paddockTurning

local function finite(value) return type(value) == 'number' and value == value and math.abs(value) < math.huge end
local function validPosition(value)
  return type(value) == 'table' and finite(value.x) and finite(value.y) and finite(value.z)
end
local function smoothstep(value)
  local t = math.max(0, math.min(1, value))
  return t * t * (3 - 2 * t)
end
local function readFov()
  local value = core_camera.getFovDeg and core_camera.getFovDeg()
  return finite(value) and value > 0 and value < 180 and value or nil
end

local function setFov(value)
  if not core_camera.setFOV then return end
  core_camera.setFOV(0, value)
  local globals = core_camera.getGlobalCameras and core_camera.getGlobalCameras()
  local zoom = globals and globals.free and globals.free.manualzoom
  if zoom then zoom.lastNotifiedFov = value end
end

local function framingFov(frames, position, rotation)
  local aspect = 16 / 9
  local video = GFXDevice and GFXDevice.getVideoMode and GFXDevice.getVideoMode()
  if video and finite(video.width) and finite(video.height) and video.width > 0 and video.height > 0 then aspect = video.width / video.height end
  local forward, right, up = rotation * vec3(0, 1, 0), rotation * vec3(1, 0, 0), rotation * vec3(0, 0, 1)
  local tangent = 0
  for _, frame in ipairs(frames) do
    local offset = frame.center - position
    local depth = offset:dot(forward) - frame.radius
    if depth <= .1 then return 120 end
    tangent = math.max(tangent, (math.abs(offset:dot(right)) + frame.radius) / (depth * aspect),
      (math.abs(offset:dot(up)) + frame.radius) / depth)
  end
  return math.max(12, math.min(120, math.deg(2 * math.atan(tangent * 1.2))))
end

local function readCameras()
  local view = jsonReadFile('/levels/' .. getCurrentLevelIdentifier() .. '/overhaul/motorsport/motorsportSpectator.camera.json')
  if type(view) ~= 'table' then return end
  local result = {}
  local idleTargets = {}
  for _, target in ipairs(type(view.idleTargets) == 'table' and view.idleTargets or {}) do
    if validPosition(target) then idleTargets[#idleTargets + 1] = target end
  end
  for index, camera in ipairs(type(view.cameras) == 'table' and view.cameras or {view}) do
    local p, r = type(camera) == 'table' and camera.position, type(camera) == 'table' and camera.rotation
    local finish = type(camera) == 'table' and camera.finishPosition
    local sidefollow = type(camera) == 'table' and camera.mode == 'sidefollow'
    if type(p) == 'table' and type(r) == 'table' and finite(p.x) and finite(p.y) and finite(p.z)
      and finite(r.x) and finite(r.y) and finite(r.z) and finite(r.w)
      and (not sidefollow or type(finish) == 'table' and finite(finish.x) and finite(finish.y) and finite(finish.z)
        and (vec3(finish) - vec3(p)):length() > .1) then
      result[#result + 1] = {name = type(camera.name) == 'string' and camera.name ~= '' and camera.name or ('Camera ' .. index),
        position = p, rotation = r, mode = sidefollow and 'sidefollow' or nil, finishPosition = sidefollow and finish or nil,
        stagePosition = validPosition(camera.stagePosition) and camera.stagePosition or nil,
        paddockPosition = validPosition(camera.paddockPosition) and camera.paddockPosition or nil,
        paddockTarget = validPosition(camera.paddockTarget) and camera.paddockTarget
          or validPosition(view.paddockTarget) and view.paddockTarget or nil,
        idleTargets = #idleTargets > 0 and idleTargets or nil}
    end
  end
  if #result > 0 then return result end
end

local function applyCamera(index)
  local camera = cameras[index]
  if not camera then return false end
  cameraIndex = index
  trackingTarget, originalPosition, originalRotation = nil, nil, nil
  zoomFov = nil
  leaderBlend = 0
  followDistance, rolloutElapsed, previousPhase = nil, 0, nil
  idleView, rolloutPosition, paddockTurning = nil, nil, nil
  core_camera.setByName(0, 'free')
  local p, r = camera.position, camera.rotation
  if camera.mode == 'sidefollow' and camera.paddockPosition and camera.paddockTarget then
    p = camera.paddockPosition
  end
  if camera.paddockTarget then
    r = quatFromDir((vec3(camera.paddockTarget) - vec3(p)):normalized(), vec3(0, 0, 1))
  end
  core_camera.setPosRot(0, p.x, p.y, p.z, r.x, r.y, r.z, r.w)
  setFov(baseFov or 65)
  return true
end

function M.cameraState()
  return {cameraCount = #cameras, cameraIndex = cameraIndex, cameraName = cameras[cameraIndex] and cameras[cameraIndex].name}
end

function M.cycleCamera()
  if not watching or #cameras == 0 then return false, 'Enter spectator mode to change cameras.' end
  applyCamera(cameraIndex % #cameras + 1)
  return true, M.cameraState()
end

function M.isWatching() return watching end
function M.setWatching(value)
  if value then
    local available = readCameras()
    if not available then return false, 'No spectator camera is configured at this venue.' end
    if not watching then
      previousCamera = core_camera.getActiveCamName(0)
      previousFov = readFov()
      baseFov = previousCamera == 'free' and previousFov or 65
      if previousCamera == 'free' then previousPosition, previousRotation = vec3(core_camera.getPosition()), quat(core_camera.getQuat()) end
    end
    cameras = available
    applyCamera(math.max(1, math.min(cameraIndex, #cameras)))
  elseif watching then
    core_camera.setByName(0, previousCamera or 'orbit')
    if previousCamera == 'free' and previousPosition and previousRotation then
      local p, r = previousPosition, previousRotation
      core_camera.setPosRot(0, p.x, p.y, p.z, r.x, r.y, r.z, r.w)
      if previousFov then setFov(previousFov) end
    end
    previousCamera, previousPosition, previousRotation, cameras, cameraIndex = nil, nil, nil, {}, 0
    previousFov, baseFov, zoomFov = nil, nil, nil
  end
  trackingTarget, originalPosition, originalRotation = nil, nil, nil
  idleView, rolloutPosition, paddockTurning = nil, nil, nil
  leaderBlend = 0
  watching = value == true
  hud.update(watching)
  if guihooks then guihooks.trigger('MotorsportSpectatorWatching', watching) end
  return true
end

function M.resetView(resetMoving)
  local camera = cameras[cameraIndex]
  if camera and (camera.mode == 'sidefollow' or camera.idleTargets) and not resetMoving then return end
  if originalPosition and M.isWatching() and core_camera.getActiveCamName(0) == 'free' then
    local p, r = originalPosition, originalRotation
    core_camera.setPosRot(0, p.x, p.y, p.z, r.x, r.y, r.z, r.w)
    if zoomFov then setFov(baseFov or 65) end
  end
  trackingTarget, originalPosition, originalRotation = nil, nil, nil
  zoomFov = nil
  leaderBlend = 0
  followDistance, rolloutElapsed, previousPhase = nil, 0, nil
  idleView, rolloutPosition, paddockTurning = nil, nil, nil
end

local function idleLook(camera, dt)
  local position, rotation = core_camera.getPosition(), core_camera.getQuat()
  if not idleView then idleView = {index = (cameraIndex - 1) % #camera.idleTargets + 1, elapsed = 0, rotation = quat(rotation)} end
  local offset = vec3(camera.idleTargets[idleView.index]) - position
  if offset:length() < .1 then return end
  local desired = quatFromDir(offset:normalized(), vec3(0, 0, 1))
  if idleView.rotation:dot(desired) < 0 then desired = -desired end
  local angle = 2 * math.acos(math.min(1, math.abs(idleView.rotation:dot(desired))))
  local pause = 2.5 + math.sin(idleView.index * 1.7 + cameraIndex)
  local duration = math.max(5, angle / math.rad(6) * 1.5)
  idleView.elapsed = idleView.elapsed + dt
  rotation = idleView.rotation:slerp(desired, smoothstep((idleView.elapsed - pause) / duration))
  core_camera.setPosRot(0, position.x, position.y, position.z, rotation.x, rotation.y, rotation.z, rotation.w)
  local current = zoomFov or readFov() or 65
  zoomFov = current + (65 - current) * (1 - math.exp(-.35 * dt))
  if math.abs(zoomFov - current) > .001 then setFov(zoomFov) end
  if idleView.elapsed >= pause + duration then
    idleView = {index = idleView.index % #camera.idleTargets + 1, elapsed = 0, rotation = quat(rotation)}
  end
end

function M.update(rows, phase, dtSim, raceDirection)
  hud.update(M.isWatching())
  if not M.isWatching() or core_camera.getActiveCamName(0) ~= 'free' then return end
  local camera = cameras[cameraIndex]
  local paddockTracking = camera.paddockTarget ~= nil
  local rollout = camera.mode == 'sidefollow' and camera.stagePosition and camera.paddockPosition and camera.paddockTarget
  if paddockTracking and phase == 'approaching' and previousPhase ~= phase then
    if camera.idleTargets then
      rolloutPosition = vec3(core_camera.getPosition())
      idleView, paddockTurning, rolloutElapsed, followDistance, leaderBlend = nil, true, 0, nil, 0
    else applyCamera(cameraIndex) end
  end
  previousPhase = phase
  local dt = math.max(0, dtSim or 0)
  if camera.idleTargets and (phase == 'idle' or phase == 'preparing') then idleLook(camera, dt); return end
  if phase ~= 'racing' and phase ~= 'cooldown' and not (paddockTracking and phase == 'approaching') then
    M.resetView(not paddockTracking and phase == 'approaching'); return
  end
  local target, count, frames = vec3(), 0, {}
  for _, row in ipairs(rows or {}) do
    local vehicle = be:getObjectByID(row.id)
    if vehicle then
      local center, radius = vehicle:getPosition() + vec3(0, 0, 1), 4
      target = target + vehicle:getPosition()
      count = count + 1
      if vehicle.getSpawnWorldOOBB then
        local box = vehicle:getSpawnWorldOOBB()
        if box then center, radius = box:getCenter(), math.max(2, box:getHalfExtents():length()) end
      end
      frames[#frames + 1] = {center = center, radius = radius}
    end
  end
  if count == 0 then
    if camera.idleTargets and phase == 'cooldown' then idleLook(camera, dt) else M.resetView() end
    return
  end
  idleView = nil
  target = target / count + vec3(0, 0, 1)
  local position = core_camera.getPosition()
  if not originalPosition then originalPosition, originalRotation = vec3(position), quat(core_camera.getQuat()) end
  if paddockTracking and phase == 'approaching' then
    rolloutElapsed = rolloutElapsed + dt
    target = vec3(camera.paddockTarget) + (target - vec3(camera.paddockTarget)) * smoothstep(rolloutElapsed / 3)
  end
  if (phase == 'racing' or phase == 'cooldown') and raceDirection and #frames == 2 then
    local forward = vec3(raceDirection)
    if forward:length() > .001 then
      local gap = (frames[2].center - frames[1].center):dot(forward:normalized())
      local leader = frames[gap > 0 and 2 or 1]
      local moving = camera.mode == 'sidefollow'
      local desiredBlend = math.max(0, math.min(1, (math.abs(gap) - (moving and 10 or 15)) / (moving and 15 or 20)))
      leaderBlend = leaderBlend + (desiredBlend - leaderBlend) * (1 - math.exp(-6 * dt))
      target = target + (leader.center - target) * leaderBlend
      for _, frame in ipairs(frames) do
        if frame ~= leader then
          frame.center = frame.center + (leader.center - frame.center) * leaderBlend
          frame.radius = frame.radius + (leader.radius - frame.radius) * leaderBlend
        end
      end
    end
  end
  if camera.mode == 'sidefollow' then
    local start = vec3(camera.position)
    local path = vec3(camera.finishPosition) - start
    local direction, length = path:normalized(), path:length()
    if rollout and phase == 'approaching' then
      position = vec3(camera.paddockPosition)
      if rolloutPosition then position = rolloutPosition + (position - rolloutPosition) * smoothstep(rolloutElapsed / 6) end
    else
      local progress = (target - (rollout and vec3(camera.stagePosition) or start)):dot(direction)
      if rollout then progress = math.max(0, progress) end
      local lead = rollout and 15 * (1 - smoothstep(progress / 80)) or 0
      local distance = math.min(length, progress + lead)
      followDistance = math.max(followDistance or (rollout and distance or 0), distance)
      position = start + direction * followDistance
    end
  end
  trackingTarget = trackingTarget or position + core_camera.getQuat() * vec3(0, 50, 0)
  trackingTarget = camera.mode == 'sidefollow' and target or trackingTarget + (target - trackingTarget) * (1 - math.exp(-4 * dt))
  local direction = trackingTarget - position
  if direction:length() < .1 then return end
  local rotation = quatFromDir(direction:normalized(), vec3(0, 0, 1))
  if paddockTurning then
    local current = core_camera.getQuat()
    if current:dot(rotation) < 0 then rotation = -rotation end
    local angle = 2 * math.acos(math.min(1, math.abs(current:dot(rotation))))
    if angle > math.rad(.75) then
      rotation = current:slerp(rotation, math.min(1 - math.exp(-1.4 * dt), math.rad(10) * dt / angle))
    else paddockTurning = nil end
  end
  core_camera.setPosRot(0, position.x, position.y, position.z, rotation.x, rotation.y, rotation.z, rotation.w)
  local desired = framingFov(frames, position, rotation)
  if camera.mode == 'sidefollow' and phase ~= 'approaching' then desired = math.min(75, desired) end
  local current = zoomFov or baseFov or 65
  zoomFov = current + (desired - current) * (1 - math.exp(-(desired > current and 8 or 2) * dt))
  if camera.mode == 'sidefollow' and phase ~= 'approaching' then zoomFov = math.min(75, zoomFov) end
  if math.abs(zoomFov - current) > .001 then setFov(zoomFov) end
end

return M
