-- Holds gearbox state during career pauses and restores it when simulation resumes.
-- Read vehicle state capture, pause transitions, frame updates and lifecycle hooks.
local M = {}

local savedGear = nil
local wasPaused = false
local restoreArmed = false

local function restoreGear(index)
  if index == nil then return end
  local gb = powertrain and powertrain.getDevice and powertrain.getDevice("gearbox")
  if gb and gb.setGearIndex then
    gb:setGearIndex(index, 0)
    if electrics and electrics.values then
      electrics.values.gearIndex = index
    end
    return
  end
  if not powertrain or not powertrain.getDevicesByType then return end
  for _, typeName in ipairs({"automaticGearbox", "dctGearbox", "manualGearbox", "sequentialGearbox"}) do
    local devices = powertrain.getDevicesByType(typeName)
    if devices then
      for _, device in ipairs(devices) do
        if device.setGearIndex then
          device:setGearIndex(index, 0)
          if electrics and electrics.values then
            electrics.values.gearIndex = index
          end
          return
        end
      end
    end
  end
end

local function afterController(dt)
  local ev = electrics and electrics.values
  if not ev then return end
  if ev.gearboxMode == "none" then return end

  local gear = ev.gearIndex

  if not dt or dt <= 1e-4 then
    wasPaused = true
    return
  end

  local resumed = wasPaused
  wasPaused = false
  if resumed then
    restoreArmed = true
  end

  if restoreArmed then
    if savedGear ~= nil and math.abs(savedGear) > 1 then
      if gear ~= savedGear then
        local looksDumped = gear ~= nil and math.abs(gear) <= 1
        if looksDumped then
          restoreGear(savedGear)
          restoreArmed = false
          return
        end
        restoreArmed = false
      else
        restoreArmed = false
      end
    else
      restoreArmed = false
    end
  end

  savedGear = gear
end

function M.onReset()
  savedGear = nil
  restoreArmed = false
end

-- Extension updateGFX runs right after the controllers in the same frame.
M.updateGFX = afterController

return M
