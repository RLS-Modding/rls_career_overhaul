-- Facility work activity contract and host actions.
-- The facility owner keeps batches, truck loading and shift settlement.
return function(M)
  local function delegate(name)
    return function(...) return M[name](...) end
  end

  return {
    id = "facilityWork",
    label = "Facility work",
    role = "foreground",
    modes = {"career"},
    extension = "overhaul_jobs_facilityWork",
    lifecycle = "facilityWork",
    blocks = {"travelJournal"},
    blockingOrder = 40,
    blockingProbe = require('overhaul/lib/activity/probes').protectedBoolean(M, 'isFacilityWorkActive'),
    actions = {
      selectFacility = delegate("selectFacility"),
      setBatchSize = delegate("setBatchSize"),
      startFacilityWork = delegate("startFacilityWork"),
      endFacilityWork = delegate("endFacilityWork"),
      requestFacilityWorkState = delegate("requestFacilityWorkState"),
      completeTruckLoading = delegate("completeTruckLoading"),
      repairForklift = delegate("repairForklift"),
    },
    probe = delegate("isFacilityWorkActive"),
    transitions = {
      reload = delegate("onOverhaulBeforeLuaReload"),
      stop = delegate("onOverhaulActive"),
      unload = delegate("onClientEndMission"),
    },
    resources = {"vehicle", "route", "tasklist", "traffic"},
    settlement = "owner",
    economyKeys = {"facilityWork"},
  }
end
