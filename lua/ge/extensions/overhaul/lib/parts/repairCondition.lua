-- Stock initialization prefers detailed state over numeric integrity.
-- Keep fuel, but dispatch numeric healthy conditions to every saved device.
local M = {}

function M.clearIntegrityStateKeepFuel(info)
  local state = info.integrityState
  info.integrityState = nil
  if type(state) ~= 'table' or type(state.energyStorage) ~= 'table' then return end

  for _, tank in pairs(state.energyStorage) do
    if type(tank) == 'table' then
      for key in pairs(tank) do
        if key ~= 'storedEnergy' then tank[key] = nil end
      end
    end
  end
  info.integrityState = {energyStorage = state.energyStorage}
  if type(state.powertrain) == 'table' then
    info.integrityState.powertrain = {}
    for deviceName in pairs(state.powertrain) do
      info.integrityState.powertrain[deviceName] = 1
    end
  end
end

return M
