-- VE dyno brake load; overhaulDynoSession calls activate(), startPull(), stopPull(), release().
-- Read state, unloaded-shaft inertia, brake loads, frame updates, then lifecycle and exports.
local M = {}
local active = false
local rebuild = false
local tracked = {}
local ownsRamp = false

local function isDynoPart(origin)
  return type(origin) == "string" and (
    origin == "wheel_dyno_rls_F5" or origin == "wheel_dyno_rls_R5"
    or origin:match("^dshub_dyno_[FR]_") ~= nil)
end

local function dynoWheelNames()
  local names = {}
  for _, wheel in pairs(v.data.wheels or {}) do
    if isDynoPart(wheel.partOrigin) then names[wheel.name] = true end
  end
  return names
end

local function onlyDynoWheels(device, names, visited)
  if visited[device] then return false end
  visited[device] = true
  if device.connectedWheel then return names[device.connectedWheel] == true end
  local found = false
  for _, child in pairs(device.children or {}) do
    if not onlyDynoWheels(child, names, visited) then return false end
    found = true
  end
  return found
end

local function stateKey(device)
  return tostring(device.mode) .. ":" .. tostring(device.isBroken)
    .. ":" .. tostring(device.gearRatio) .. ":" .. tostring(device.parent.defaultVirtualInertia)
end

local function canDisconnect(device)
  for _, mode in pairs(device.availableModes or {}) do
    if mode == "disconnected" then return true end
  end
  return false
end

local function restore(recalculate)
  local changed = false
  for device, entry in pairs(tracked) do
    if device.calculateInertia == entry.wrapper then
      device.calculateInertia = entry.native
      changed = true
    end
  end
  tracked = {}
  if changed and recalculate then powertrain.calculateTreeInertia() end
end

local function attach()
  restore(false)
  local names = dynoWheelNames()
  if not next(names) then return end
  for _, device in pairs(powertrain.getDevices()) do
    local parent = device.parent
    local inertia = parent and tonumber(parent.defaultVirtualInertia)
    if device.type == "shaft" and canDisconnect(device) and not device.connectedWheel and inertia and inertia > 0
      and type(device.calculateInertia) == "function"
      and onlyDynoWheels(device, names, {}) then
      local native = device.calculateInertia
      local function wrapper(shaft)
        native(shaft)
        local unloaded = tonumber(shaft.parent.defaultVirtualInertia)
        local ratio = tonumber(shaft.gearRatio)
        if active and shaft.mode == "disconnected" and not shaft.isBroken and unloaded and unloaded > 0 and ratio and ratio ~= 0 then
          shaft.cumulativeInertia = unloaded / (ratio * ratio)
          shaft.invCumulativeInertia = 1 / shaft.cumulativeInertia
        end
      end
      tracked[device] = {native = native, wrapper = wrapper, state = stateKey(device)}
      device.calculateInertia = wrapper
    end
  end
  if next(tracked) then powertrain.calculateTreeInertia() end
end

local function activate()
  if active and not rebuild then return end
  active, rebuild = true, false
  attach()
end

local function stopPull()
  local ramp = controller and controller.getController and controller.getController("overhaulDynoRamp")
  if ramp then ramp.setEnabled(false) end
end

local function startPull()
  activate()
  if not controller or not controller.getController or not controller.loadControllerExternal then return end
  local ramp = controller.getController("overhaulDynoRamp")
  if not ramp then
    ramp = controller.loadControllerExternal("overhaulDynoRamp", "overhaulDynoRamp")
    ownsRamp = ramp ~= nil
  end
  if ramp then ramp.setEnabled(true) end
end

local function release()
  stopPull()
  if ownsRamp then
    if controller.getController("overhaulDynoRamp") then controller.unloadControllerExternal("overhaulDynoRamp") end
    ownsRamp = false
  end
  active, rebuild = false, false
  restore(true)
end

local function updateGFX()
  if not active then return end
  if rebuild then
    rebuild = false
    attach()
    return
  end
  local changed = false
  for device, entry in pairs(tracked) do
    local state = stateKey(device)
    if state ~= entry.state then entry.state, changed = state, true end
  end
  if changed then powertrain.calculateTreeInertia() end
end

M.activate = activate
M.startPull = startPull
M.stopPull = stopPull
M.release = release
M.updateGFX = updateGFX
M.onReset = function()
  stopPull()
  -- Reset hooks run before native powertrain reset/reconstruction.
  restore(false)
  rebuild = active
end
M.onExtensionUnloaded = release
return M
