-- Ambulance activity actions, projections and lifecycle delegates.
-- The activity host calls the existing owner; it holds no separate job state.
return function(M)
  local function delegate(name)
    return function(...) return M[name](...) end
  end

  return {
    id = "ambulance",
    label = "Ambulance roleplay shift",
    role = "child",
    parent = "employment",
    modes = {"career"},
    extension = "overhaul_jobs_ambulance",
    lifecycle = "ambulance",
    probe = delegate("isAmbulanceJobActive"),
    blocks = {"travelJournal"},
    blockingOrder = 50,
    blockingProbe = require('overhaul/lib/activity/probes').protectedBoolean(M, 'isAmbulanceJobActive'),
    actions = {
      requestEndDay = delegate("requestEndDay"),
      cancelActiveCall = delegate("cancelActiveCall"),
    },
    transitions = {
      stop = delegate("onOverhaulActive"),
      switch = delegate("onOverhaulBeforeSetProfile"),
      unload = delegate("onClientEndMission"),
    },
    resources = {"vehicle", "route", "tasklist"},
    settlement = "parent",
    economyKeys = {"ambulance"},
  }
end
