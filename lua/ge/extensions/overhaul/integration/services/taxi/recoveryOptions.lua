-- The recovery menu's existing Call taxi option, including its company label and readiness retry.
-- Menu construction uses this stateless provider; only pressing the option may load the taxi service.
local M = {}
local optional = require('overhaul/lib/platform/optional')

function M.label()
  local transfer = optional('overhaul_career_logistics_vehicleTransfer')
  local onShift = transfer and transfer.isOnShift and transfer.isOnShift()
  if not onShift then
    local employment = optional('overhaul_career_work_employment')
    onShift = employment and employment.isOnShift and employment.isOnShift()
  end
  return onShift and 'Call a taxi (Company pays)' or 'Call a taxi'
end

function M.available()
  return true
end

local function taxiReady()
  local playerDriving = optional('overhaul_career_police_playerDriving')
  return playerDriving and playerDriving.ensureVanillaTaxiReady and playerDriving.ensureVanillaTaxiReady()
end

function M.run()
  local ready = taxiReady()
  if not ready then
    -- Stock extensions.load requires the module unprotected, so a taxi owner that errors while loading must not abort the prompt.
    local ok, reason = pcall(extensions.load, 'overhaul_integration_services_taxi')
    if not ok then log('W', 'taxiRecovery', 'Taxi service failed to load: ' .. tostring(reason)) end
    ready = taxiReady()
  end
  local taxi = optional('overhaul_integration_services_taxi')
  if ready and taxi and taxi.callForTaxi then
    taxi.callForTaxi()
  else
    ui_message('Taxi service is currently unavailable.', 5, 'taxi', 'warning')
  end
end

return M
