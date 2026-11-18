-- Shared healthy clutch capacity contract. Providers publish total required
-- bases; the largest requirement wins. Maintenance applies condition afterwards.
local M = {}
local devices = setmetatable({}, {__mode = 'k'})

local function positive(value)
  return type(value) == 'number' and value > 0 and value < math.huge
end

-- Capture before any consumer derates the device. The optional baseline lets
-- an existing hardware snapshot seed the registry after a context rebuild.
function M.originalLockTorque(device, baseline)
  local record = devices[device]
  if record then return record.original end
  local original = baseline or device.lockTorque
  if positive(original) then
    devices[device] = {original = original, base = original, providers = {}}
  end
  return original
end

function M.lockTorqueBase(device, fallback)
  local record = devices[device]
  return record and record.base or fallback
end

local function refresh(device, record)
  local base = record.original
  for _, value in pairs(record.providers) do base = math.max(base, value) end
  if base == record.base then return end
  -- Preserve the live maintenance reduction between its own apply ticks.
  device.lockTorque = device.lockTorque * base / record.base
  record.base = base
  if device.calculateInertia then device:calculateInertia() end
end

function M.setLockTorqueBase(device, owner, value)
  if owner == nil or not positive(value) then return false end
  M.originalLockTorque(device)
  local record = devices[device]
  if not record then return false end
  record.providers[owner] = value
  refresh(device, record)
  return true
end

function M.releaseLockTorqueBase(device, owner)
  local record = devices[device]
  if not record or owner == nil or record.providers[owner] == nil then return end
  record.providers[owner] = nil
  refresh(device, record)
end

return M
