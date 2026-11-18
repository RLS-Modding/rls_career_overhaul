-- Fixed, engine-definition-based dyno load. No RPM target or elapsed-time feedback.
-- A preset is compiled for the selected gear; only physical hub brakes are written.
local M = {type = 'auxiliary', defaultOrder = 1000000}
local avToRPM = require('common/overhaul/units').AV_TO_RPM
local enabled, engine, definition, setup = false, nil, nil, nil
local hubs, appliedLoads, loadCache = {}, {}, {}
local preset = 'standard'
local presets = {light = 6, standard = 8, heavy = 10}
local function finite(x) return type(x) == 'number' and x == x and math.abs(x) < math.huge end
local function clamp(x, low, high) return math.max(low, math.min(high, x)) end
local function releaseLoads()
  for wheel, load in pairs(appliedLoads) do
    if wheel.desiredBrakingTorque == load.applied then wheel.desiredBrakingTorque = load.base end
  end
  appliedLoads, loadCache = {}, {}
end
local function reset()
  releaseLoads()
  enabled, setup = false, nil
end
local function readDefinition()
  definition = nil
  if not engine then return end
  local data = engine.torqueData or {}
  local curve
  -- Don't assume nitrous is being sprayed just because a bottle is fitted.
  for _, candidate in ipairs(data.curves or {}) do
    if not tostring(candidate.name):find('N2O', 1, true) then curve = candidate; break end
  end
  local limit = engine.revLimiterRPM or engine.maxRPM or data.maxRPM
  if not curve or type(curve.torque) ~= 'table' or not finite(limit) or limit <= 0 then return end
  local hp = 0
  local points = {}
  for rpm = 0, math.ceil(limit / 100) * 100, 100 do
    local torque = curve.torque[math.min(math.floor(limit)-1, rpm) + 1]
    torque = finite(torque) and math.max(0, torque) or 0
    points[#points+1] = {rpm = rpm, torque = torque}
    hp = math.max(hp, torque * rpm / avToRPM / 745.699872)
  end
  -- Snapshot at arming: later engine/tuning changes cannot move the load setting.
  definition = {points = points, maxRPM = limit, idleRPM = engine.idleRPM or 800, horsepower = hp,
    band = hp < 250 and 'under250' or hp < 500 and '250to500' or hp < 1000 and '500to1000'
      or hp < 1500 and '1000to1500' or '1500plus'}
end
local function init()
  reset()
  hubs = {}
  engine = powertrain.getDevice('mainEngine') or (powertrain.getDevicesByCategory('engine') or {})[1]
  for _, wheel in pairs(wheels.wheels or {}) do
    local origin = (v.data.wheels[wheel.cid] or {}).partOrigin or ''
    if origin == 'wheel_dyno_rls_F5' or origin == 'wheel_dyno_rls_R5' or origin:match('^dshub_dyno_[FR]_') then
      hubs[wheel.name] = wheel
    else
      hubs = {}; return -- No absorber on stock or mixed road/dyno wheels.
    end
  end
end
local function prepare(gearbox)
  if not definition then return end
  local branches, seen = {}, {}
  local function visit(device, ratio)
    if seen[device] or device.isBroken or device.mode == 'disconnected' then return end
    seen[device] = true
    ratio = ratio * math.abs(device.gearRatio or 1)
    if ratio <= 0 then return end
    if device.connectedWheel then
      local wheel = hubs[device.connectedWheel]
      if wheel then branches[#branches+1] = {wheel=wheel, ratio=ratio} end
    else
      for _, child in pairs(device.children or {}) do visit(child, ratio) end
    end
  end
  visit(gearbox, 1)
  if #branches == 0 then return end
  local inertia = (engine.inertia or 0) + (gearbox.cumulativeInertia or 0)
  if not finite(inertia) or inertia <= 0 then return end
  local seconds = presets[preset]
  if preset == 'standard' and definition.horsepower < 250 then seconds = 9 end
  local startRPM = math.max(definition.idleRPM * 2, math.min(3000, definition.maxRPM * 0.3))
  -- Eight seconds is a calibration estimate used once, not a runtime command.
  local accelerationTorque = inertia * math.max(0, definition.maxRPM - startRPM) / seconds / avToRPM
  local points = {}
  for i, p in ipairs(definition.points) do
    -- Reserve a fixed 10% for driveline/model losses. Below the operating range,
    -- a predefined taper avoids loading a slipping launch clutch at engine RPM.
    local lowSpeed = clamp(p.rpm / math.max(1, startRPM), 0, 1)
    local torque = math.max(0, p.torque * 0.90 - accelerationTorque) * lowSpeed
    points[i] = {rpm = p.rpm, torque = torque}
  end
  setup = {gear = gearbox.gearIndex, ratio = gearbox.gearRatio, branches = branches, points = points,
    inertia = inertia, referenceStartRPM = startRPM, calibrationSeconds = seconds}
end
local function curveTorque(rpm)
  local points = setup.points
  local index = clamp(math.floor(rpm / 100) + 1, 1, #points - 1)
  local a, b = points[index], points[index+1]
  return a.torque + (b.torque-a.torque) * clamp((rpm-a.rpm)/(b.rpm-a.rpm), 0, 1)
end
local function updateWheelsIntermediate(dt)
  if not enabled or not engine or not next(hubs) or not definition or not finite(dt) or dt <= 0 then return end
  local gearbox = powertrain.getDevice('gearbox')
  if not gearbox then return end
  local values = electrics.values
  local throttle = input and input.throttle or values.throttle or 0
  local brake = input and input.brake or values.brake or 0
  local clutch = input and input.clutch or values.clutch or 0
  local parkingbrake = math.max(input and input.parkingbrake or 0, values.parkingbrake or 0)
  if setup and (setup.gear ~= gearbox.gearIndex or setup.ratio ~= gearbox.gearRatio) then
    releaseLoads(); setup = nil
  end
  if (gearbox.gearIndex or 0) <= 0 or gearbox.isShifting or gearbox.isShiftingUp or gearbox.isShiftingDown then
    releaseLoads(); return
  end
  if not setup then prepare(gearbox) end
  if not setup then return end
  if throttle <= 0.05 or brake > 0.02 or clutch > 0.1 or parkingbrake > 0.02
    or engine.revLimiterActive or engine.isDisabled then
    releaseLoads(); return
  end
  local engagement = clamp((throttle-0.05)/0.85, 0, 1)
  -- Anti-stall release is a safety gate, not sweep-speed regulation.
  engagement = engagement * clamp(((engine.outputAV1 or 0)*avToRPM-definition.idleRPM)/math.max(1,definition.idleRPM*.5),0,1)
  for _, branch in ipairs(setup.branches) do
    local wheel = branch.wheel
    local hubAV = (wheel.angularVelocity or 0) * (wheel.wheelDir or 1)
    local requested = 0
    if not wheel.isBroken and hubAV > 0 and (wheel.propulsionTorque or 0)*(wheel.wheelDir or 1) > 0 then
      -- Read rotor speed, not a free-revving engine. This is a precomputed load
      -- curve; neither current horsepower nor elapsed time adjusts its torque.
      requested = curveTorque(hubAV * branch.ratio * avToRPM) * branch.ratio / #setup.branches * engagement
    end
    local previous = loadCache[wheel] or 0
    local load = requested < previous and requested or previous + (requested-previous)*math.min(1,dt/.04)
    loadCache[wheel] = load
    local base = wheel.desiredBrakingTorque or 0
    local applied = math.max(base, load)
    wheel.desiredBrakingTorque = applied
    local entry = appliedLoads[wheel] or {}
    entry.base, entry.applied = base, applied
    appliedLoads[wheel] = entry
  end
end
M.init = init
M.reset = reset
M.updateWheelsIntermediate = updateWheelsIntermediate
M.setEnabled = function(value, options)
  reset()
  local selected = options and options.loadPreset or 'standard'
  preset = presets[selected] and selected or 'standard'
  if value == true then readDefinition(); enabled = true end
end
M.getState = function() return {enabled = enabled, mode = 'preset', preset = preset,
  horsepower = definition and definition.horsepower, horsepowerBand = definition and definition.band,
  maxRPM = definition and definition.maxRPM, prepared = setup ~= nil, gear = setup and setup.gear,
  inertia = setup and setup.inertia, calibrationSeconds = setup and setup.calibrationSeconds,
  referenceStartRPM = setup and setup.referenceStartRPM,
  controlled = false} end -- Fixed load does not certify a constant-speed sweep.
return M
