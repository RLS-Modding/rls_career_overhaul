-- Driver commands shared by quarry and facility trucks.
-- Keep the engine's vector constructor intact; the remaining export arguments are escaped literals.
local M = {}
local vehicleCommands = require('overhaul/lib/vehicles/vehicleCommands')

-- Static chunks avoid rebuilding the repeated hold at every loading frame.
-- AI disable restores its saved gearbox mode; select realistic afterwards so
-- holding the brake cannot become reverse throttle. Read the live mode rather
-- than caching a GE latch, which would survive a vehicle-side reset.
local holdTruck = "if ai.mode ~= 'disabled' then ai.setMode('disabled') end; "
  .. "if controller and controller.mainController then local mainController = controller.mainController; "
  .. "if mainController.setGearboxMode and mainController.gearboxBehavior ~= 'realistic' then mainController.setGearboxMode('realistic') end; "
  .. "if mainController.shiftToGearIndex then mainController.shiftToGearIndex(0) end end; "
  .. "input.event('throttle', 0, 1); input.event('clutch', 1, 1); "
  .. "input.event('brake', 1, 1); input.event('steering', 0, 2); input.event('parkingbrake', 1, 1)"
local releaseTruck = "input.event('throttle', 0, 1); input.event('clutch', 0, 1); "
  .. "input.event('brake', 0, 1); input.event('steering', 0, 2); input.event('parkingbrake', 0, 1)"
-- Manual AI still writes end-of-route brakes. A nudge owns the pedals, while
-- arcade supplies stock automatic clutch/gear selection for forward motion.
local beginTruckNudge = "ai.setMode('disabled'); "
  .. "if controller and controller.mainController and controller.mainController.setGearboxMode then "
  .. "controller.mainController.setGearboxMode('arcade') end; "
  .. releaseTruck

function M.holdTruck() return holdTruck end
function M.beginTruckNudge() return beginTruckNudge end

function M.returnTargetPosition(positionLiteral)
  local call = vehicleCommands.call('overhaulDriver', 'returnTargetPosition')
  return call:sub(1, -2) .. positionLiteral .. ', ' .. vehicleCommands.luaLiteral(false)
    .. ', ' .. vehicleCommands.luaLiteral('limit') .. ', ' .. vehicleCommands.luaLiteral(true) .. ')'
end

function M.routeTruck(positionLiteral)
  -- The route builder can fail before enabling AI (no usable road path). A
  -- truck in neutral must keep its brakes until the driver accepts the route.
  return 'if ' .. M.returnTargetPosition(positionLiteral) .. ' then '
    .. releaseTruck .. " else " .. holdTruck
    .. "; log('W', 'truckCommands', 'Route rejected; truck remains held') end"
end

return M
