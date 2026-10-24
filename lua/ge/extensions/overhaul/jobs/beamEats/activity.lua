-- BeamEats activity actions, projections and lifecycle delegates.
-- The activity host calls the existing owner; it holds no separate job state.
return function(M)
  local function delegate(name)
    return function(...) return M[name](...) end
  end

  return {
    id = "beamEats",
    label = "BeamEats",
    role = "foreground",
    modes = {"career"},
    extension = "overhaul_jobs_beamEats",
    lifecycle = "beamEats",
    blocks = {"travelJournal"},
    blockingOrder = 30,
    blockingProbe = require('overhaul/lib/activity/probes').protectedBoolean(M, 'isBeamEatsJobActive'),
    actions = {
      setAvailable = delegate("setAvailable"),
      stopBeamEatsJob = delegate("stopBeamEatsJob"),
      acceptOrder = delegate("acceptOrder"),
      rejectOrder = delegate("rejectOrder"),
      dismissSummary = delegate("dismissSummary"),
      requestBeamEatsState = delegate("requestBeamEatsState"),
    },
    probe = delegate("isBeamEatsJobActive"),
    save = delegate("onOverhaulSaveCurrentProfile"),
    transitions = {
      save = delegate("onOverhaulSaveCurrentProfile"),
      switch = delegate("onOverhaulBeforeSetProfile"),
    },
    resources = {"route", "tasklist"},
    settlement = "owner",
    economyKeys = {"beamEats"},
  }
end
