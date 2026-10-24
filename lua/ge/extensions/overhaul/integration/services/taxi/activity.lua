-- The hired cab as an activity definition, adopted by the activity host (lib/activity/access.lua).
-- Each callable delegates to the service's export table at call time and keeps no state of its own.

return function(service)

  -- Looked up on each call so the activity follows the live service load.
  local function delegate(name)
    return function(...) return service[name](...) end
  end

  -- The ride UI's on*Called entry points are engine hooks, so they stay out of the actions.
  return {
    id = "hiredCab",
    label = "Hired cab",
    role = "foreground",
    modes = {"career", "freeroam"},
    extension = "overhaul_integration_services_taxi",
    lifecycle = "hiredCab",
    allowPhoneWhileMoving = true,
    actions = {
      callForTaxi = delegate("callForTaxi"),
      cancelTaxiCall = delegate("cancelTaxiCall"),
      startTaxiWithCurrentRoute = delegate("startTaxiWithCurrentRoute"),
      confirmTaxiDestination = delegate("confirmTaxiDestination"),
      setIdleCameraEnabled = delegate("setIdleCameraEnabled"),
    },
    probe = function() return service.isTaxiRideActive and service.isTaxiRideActive() or false end,
    transitions = {
      unload = delegate("onClientEndMission"),
    },
    resources = {"vehicle", "camera", "input", "route"},
    settlement = "owner",
  }
end
