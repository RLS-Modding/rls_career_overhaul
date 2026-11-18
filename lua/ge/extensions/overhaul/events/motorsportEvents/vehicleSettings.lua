-- Owns cached vehicle overrides from settings/motorsportEvents/vehicleSettings.json.
-- The drag runner reads launch rates; class inspection reads utility-model traits.
local M = {}
local cached

local function settings()
  if cached then return cached end
  local data = assert(jsonReadFile('/settings/motorsportEvents/vehicleSettings.json'), 'Missing Motorsport vehicle settings')
  assert(data.version == 1 and type(data.launchRecoveryRatePerSecond) == 'table'
    and type(data.utilityModels) == 'table', 'Invalid Motorsport vehicle settings')
  for id, rate in pairs(data.launchRecoveryRatePerSecond) do
    assert(type(id) == 'string' and id:match('^[%w_%-]+/[%w_%-]+$')
      and type(rate) == 'number' and rate >= .1 and rate <= 2, 'Invalid Motorsport launch rate: ' .. tostring(id))
  end
  for model, enabled in pairs(data.utilityModels) do
    assert(type(model) == 'string' and model ~= '' and type(enabled) == 'boolean', 'Invalid Motorsport utility model')
  end
  cached = data
  return cached
end

function M.launchRate(entrant)
  if type(entrant.config) ~= 'string' then return nil end
  local config = (entrant.config:match('([^/]+)$') or ''):gsub('%.pc$', '')
  return settings().launchRecoveryRatePerSecond[tostring(entrant.model) .. '/' .. config]
end

function M.isUtilityModel(model) return settings().utilityModels[model] == true end

return M
