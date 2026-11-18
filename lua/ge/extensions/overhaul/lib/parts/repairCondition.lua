-- Dispatch healthy native conditions while retaining fuel and installed calibration.
local M = {}
function M.clearIntegrityStateKeepFuel(info)
  local state = info.integrityState
  info.integrityState = nil
  if type(state) ~= 'table' then return end
  local kept = {}
  if type(state.energyStorage) == 'table' then
    for _, tank in pairs(state.energyStorage) do
      if type(tank) == 'table' then
        for key in pairs(tank) do
          if key ~= 'storedEnergy' and key ~= 'rlsFuelTank' then tank[key] = nil end
        end
      end
    end
    kept.energyStorage = state.energyStorage
  end
  local engines, hasCalibration = {}, false
  for name, device in pairs(type(state.powertrain) == 'table' and state.powertrain or {}) do
    engines[name] = 1
    if type(device) == 'table' and type(device.rlsFuelEngineState) == 'table' then
      hasCalibration = true
      engines[name] = {
        rlsFuelEngineState = require('common/rlsFuelModel').repairedEngineState(device.rlsFuelEngineState),
        damageFrictionCoef = 1, damageDynamicFrictionCoef = 1, damageIdleAVReadErrorRangeCoef = 1,
        fastIgnitionErrorChance = 0, slowIgnitionErrorChance = 0, isBroken = false, thermals = {}
      }
    end
  end
  if kept.energyStorage or hasCalibration then
    if type(state.powertrain) == 'table' then kept.powertrain = engines end
    info.integrityState = kept
  end
end
return M
