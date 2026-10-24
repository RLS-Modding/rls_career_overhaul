-- Employment's bus-kind adapter: admission, end-of-route requests and shift presentation.
-- A forced end must match the active route id so stale phone actions cannot end a replacement route.
local M = {}

function M.allowsPersonalVehicle(vehicleId)
  return overhaul_jobs_bus.canUsePersonalVehicle(vehicleId)
end

function M.finalAssignment()
  return overhaul_jobs_bus.isBusRouteActive() or false
end

function M.requestEndShift(shift, force, expectedRouteId)
  local bus = overhaul_jobs_bus
  if force then
    local route = bus.getShiftState()
    if not route.active or not expectedRouteId or route.routeId ~= expectedRouteId then return false end
    shift.endAfterAssignment = true
    return bus.requestEndShift(true)
  end
  bus.requestEndShift(false)
  return true
end

function M.guidance()
  return overhaul_jobs_bus.getEmploymentTaskGuidance()
end

function M.presentation(shift)
  local bus = overhaul_jobs_bus
  local route = bus.getShiftState()
  local guidance = route and not route.paused and not shift.endAfterAssignment and M.guidance() or nil
  return {busState = route, busGuidance = guidance}
end

function M.cancelAssignment(reason)
  overhaul_jobs_bus.cancelActiveRoute(reason)
end

return M
