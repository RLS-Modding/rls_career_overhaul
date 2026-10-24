-- Bus activity controls adopted by the employment host.
-- Read the live-instance delegates and pending-route probe, then the activity definition.

return function(M)
  local function delegate(name)
    return function(...) return M[name](...) end
  end

  return {
    id = "bus",
    label = "Bus roleplay shift",
    role = "child",
    parent = "employment",
    modes = {"career"},
    extension = "overhaul_jobs_bus",
    lifecycle = "bus",
    probe = delegate("isBusRouteActive"),
    blocks = {"travelJournal"},
    blockingOrder = 60,
    blockingProbe = require('overhaul/lib/activity/probes').protectedBoolean(M, 'isBusRouteActive'),
    -- Employment ends or cancels its child; the activity keeps no independent route state.
    actions = {
      requestEndShift = delegate("requestEndShift"),
      cancelActiveRoute = delegate("cancelActiveRoute"),
    },
    transitions = {
      stop = delegate("onOverhaulActive"),
      switch = delegate("onOverhaulBeforeSetProfile"),
      unload = delegate("onClientEndMission"),
    },
    resources = {"vehicle", "route", "tasklist"},
    settlement = "parent",
    economyKeys = {"bus"},
  }
end
