-- Hub-dyno absorber: use the same engine-speed sweep in every drive mode.
-- Apply real rotor braking torque; horsepower remains measured at the hubs.
local M = {type = "auxiliary", defaultOrder = 1000000}
local enabled = false
local hubs = {}
local engine
local targetRPM
local sweepTime, errorRPM = 0, 0
local integral = 0
local torqueCache = {}
local appliedLoads = {}
local sweepRate = 300
local units = require('common/overhaul/units')
local avToRPM = units.AV_TO_RPM

local function reset()
  for wheel, load in pairs(appliedLoads) do
    if wheel.desiredBrakingTorque == load.applied then wheel.desiredBrakingTorque = load.base end
  end
  appliedLoads = {}
  enabled, targetRPM, integral = false, nil, 0
  sweepTime, errorRPM = 0, 0
  torqueCache = {}
end

local function init()
  reset()
  hubs = {}
  engine = powertrain.getDevice("mainEngine") or (powertrain.getDevicesByCategory("engine") or {})[1] -- [1] is pairs()-ordered on hybrids
  for _, wheel in pairs(wheels.wheels or {}) do
    local data = v.data.wheels[wheel.cid] or {}
    local origin = data.partOrigin or ""
    if origin == "wheel_dyno_rls_F5" or origin == "wheel_dyno_rls_R5" or origin:match("^dshub_dyno_[FR]_") then
      hubs[#hubs + 1] = wheel
    else
      -- Never apply a dyno absorber to a vehicle with road wheels.
      hubs = {}
      return
    end
  end
end

local function updateWheelsIntermediate(dt)
  if not enabled or not engine or #hubs == 0 then return end
  local values = electrics.values
  local throttle = input and input.throttle or values.throttle or 0
  local brake = input and input.brake or values.brake or 0
  local clutch = input and input.clutch or values.clutch or 0
  local gearbox = powertrain.getDevice("gearbox")
  if throttle < 0.9 or brake > 0.02 or clutch > 0.1 or (values.parkingbrake or 0) > 0.02
    or engine.revLimiterActive or (gearbox and (gearbox.gearIndex or 0) <= 0) then
    targetRPM, integral = nil, 0
    sweepTime, errorRPM = 0, 0
    return
  end
  local rpm = (engine.outputAV1 or 0) * avToRPM
  targetRPM = (targetRPM or rpm) + sweepRate * dt
  local error = rpm - targetRPM
  sweepTime, errorRPM = sweepTime + dt, error
  integral = math.max(0, math.min(0.98, integral + error * dt * 0.001))
  local fraction = math.max(0, math.min(0.98, error * 0.002 + integral))
  for _, wheel in ipairs(hubs) do
    local drivingTorque = (wheel.propulsionTorque or 0) * (wheel.wheelDir or 1)
    local smoothTorque = (torqueCache[wheel] or drivingTorque) + (drivingTorque - (torqueCache[wheel] or drivingTorque)) * math.min(1, dt / 0.1)
    torqueCache[wheel] = smoothTorque
    if not wheel.isBroken and drivingTorque > 0 and (wheel.angularVelocity or 0) * (wheel.wheelDir or 1) > 0 then
      local base = wheel.desiredBrakingTorque or 0
      local applied = math.max(base, smoothTorque * fraction)
      wheel.desiredBrakingTorque = applied
      local load = appliedLoads[wheel] or {}
      load.base, load.applied = base, applied
      appliedLoads[wheel] = load
    end
  end
end

M.init = init
M.reset = reset
M.updateWheelsIntermediate = updateWheelsIntermediate
M.setEnabled = function(value) reset(); enabled = value == true end
M.getState = function() return {enabled = enabled, targetRPM = targetRPM, sweepRate = sweepRate,
  integral = integral, hubCount = #hubs, sweepTime = sweepTime, errorRPM = errorRPM,
  controlled = targetRPM == nil or sweepTime < 4 or math.abs(errorRPM) <= 150} end
return M
