local M = {}
local active, throttle = false, 1
local recoveryRate = .65

local function finite(value) return type(value) == 'number' and value == value and math.abs(value) < math.huge end

function M.clear()
  if not active then return end
  active = false
  electrics.values.throttleOverride = nil
end

function M.start(rate)
  if active or playerInfo and playerInfo.anyPlayerSeated then return false end
  active, throttle = true, .4
  recoveryRate = finite(rate) and math.min(2, math.max(.1, rate)) or .65
  electrics.values.throttleOverride = throttle
  return true
end

function M.onPlayersChanged(seated)
  if not seated then return end
  M.clear()
  extensions.unload('overhaulMotorsportLaunch')
end

function M.updateGFX(dt)
  if not active then return end
  if playerInfo and playerInfo.anyPlayerSeated then M.onPlayersChanged(true); return end
  if not finite(dt) or dt <= 0 then return end
  local direction, velocity = obj:getDirectionVector(), obj:getVelocity()
  local speed = math.abs(velocity:dot(direction))
  if not finite(speed) or not finite(direction.z) then return end
  local drivenSpeed, count = 0, 0
  for _, wheel in pairs(wheels.wheelRotators) do
    if wheel.isPropulsed and not wheel.isBroken and finite(wheel.angularVelocity) and finite(wheel.radius) then
      drivenSpeed, count = math.max(drivenSpeed, math.abs(wheel.angularVelocity * wheel.radius)), count + 1
    end
  end
  if count == 0 then return end
  dt = math.min(dt, .05)
  local excess = drivenSpeed - speed - (2 + speed * .12)
  throttle = math.min(1, math.max(.12, throttle + dt * (excess > 0 and -math.min(4, excess * .8) or recoveryRate)))
  local lateral = math.abs(velocity.x * direction.y - velocity.y * direction.x)
  local lateralCap = math.max(.12, 1 - math.max(0, lateral - (.75 + speed * .05)) * .4)
  local pitchCap = math.max(.2, 1 - math.max(0, direction.z - .18) / .22 * .8)
  electrics.values.throttleOverride = math.min(throttle, lateralCap, pitchCap)
end

M.onReset = M.clear
M.onExtensionUnloaded = M.clear
return M
