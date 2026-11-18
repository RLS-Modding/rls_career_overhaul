local M = {}
local cooling, savedBrake, savedClutch, brakeCommand, steering = false, nil, nil, 0, 0
local origin, forward
local savedGearboxMode
local previousHeading

local function finite(value) return type(value) == 'number' and value == value and math.abs(value) < math.huge end

local function laneVectors(lane)
  if type(lane) ~= 'table' or type(lane.origin) ~= 'table' or type(lane.direction) ~= 'table' then return end
  for index = 1, 3 do if not finite(lane.origin[index]) or not finite(lane.direction[index]) then return end end
  local direction = vec3(lane.direction[1], lane.direction[2], 0)
  if direction:squaredLength() < .001 then return end
  return vec3(lane.origin), direction:normalized()
end

function M.start(lane)
  if cooling or playerInfo and playerInfo.anyPlayerSeated then return false end
  savedBrake, savedClutch = electrics.values.brakeOverride, electrics.values.clutchOverride
  origin, forward = laneVectors(lane)
  cooling, brakeCommand, steering = true, 0, 0
  previousHeading = obj:getDirectionVector()
  ai.setMode('disabled')
  local main = controller and controller.mainController
  savedGearboxMode = main and main.gearboxBehavior or electrics.values.gearboxMode
  if main and main.setGearboxMode then main.setGearboxMode('realistic') end
  input.event('steering', 0, 2)
  input.event('parkingbrake', 0, 2)
  electrics.values.throttleOverride, electrics.values.brakeOverride = 0, 0
  local gearbox = powertrain.getDevice('gearbox')
  if gearbox and (gearbox.type == 'manualGearbox' or gearbox.type == 'sequentialGearbox') then electrics.values.clutchOverride = 1 end
  return true
end

function M.clear()
  if not cooling then return end
  cooling, brakeCommand, steering, origin, forward = false, 0, 0, nil, nil
  previousHeading = nil
  input.event('steering', 0, 2)
  input.event('brake', 0, 2)
  input.event('parkingbrake', 0, 2)
  electrics.values.brakeOverride, electrics.values.clutchOverride, electrics.values.throttleOverride = savedBrake, savedClutch, nil
  local main = controller and controller.mainController
  if savedGearboxMode and main and main.setGearboxMode then main.setGearboxMode(savedGearboxMode) end
  savedGearboxMode = nil
  savedBrake, savedClutch = nil, nil
end

function M.onPlayersChanged(seated)
  if not seated then return end
  M.clear()
  extensions.unload('overhaulMotorsportCooldown')
end

function M.updateGFX(dt)
  if not cooling then return end
  if playerInfo and playerInfo.anyPlayerSeated then M.onPlayersChanged(true); return end
  if not finite(dt) or dt <= 0 then return end
  dt = math.min(dt, .05)
  local velocity = obj:getVelocity()
  local speed = velocity:length()
  if not finite(speed) then return end
  local locking = false
  for _, wheel in pairs(wheels and wheels.wheelRotators or {}) do
    if not wheel.isBroken and finite(wheel.angularVelocity) and finite(wheel.radius) and wheel.radius > 0
      and (not finite(wheel.downForceRaw) or wheel.downForceRaw > 100)
      and speed > 5 and math.abs(wheel.angularVelocity * wheel.radius) < speed * .65 then locking = true end
  end
  brakeCommand = clamp(brakeCommand + dt * (locking and -3 or 1.25), 0, .65)
  local target = 0
  if forward and speed > 1 then
    local heading = obj:getDirectionVector()
    local left = vec3(-forward.y, forward.x, 0)
    local offset = (obj:getPosition() - origin):dot(left)
    local lateralSpeed = velocity:dot(left)
    local desired = forward * math.max(18, speed * 1.25) - left * clamp(offset + lateralSpeed * .6, -4, 4)
    if heading:dot(forward) > .5 then
      local yawRate = previousHeading and math.atan2(previousHeading:cross(heading).z, previousHeading:dot(heading)) / dt or 0
      target = math.asin(clamp(heading:cross(vec3(0, 0, 1)):dot(desired:normalized()), -1, 1)) + yawRate * .15
      target = clamp(target, -math.min(.35, 8 / (speed + 10)), math.min(.35, 8 / (speed + 10)))
    end
    previousHeading = heading
  end
  steering = steering + clamp(target - steering, -dt * .3, dt * .3)
  input.event('steering', steering, 2)
  electrics.values.throttleOverride = 0
  electrics.values.brakeOverride = speed < 1 and 1 or brakeCommand
end

M.onReset = M.clear
M.onExtensionUnloaded = M.clear
return M
