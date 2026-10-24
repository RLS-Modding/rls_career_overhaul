-- Taxi activity actions, projections and lifecycle delegates.
-- The activity host calls the existing owner; it holds no separate job state.
return function(M)
  local journalProbe = require('overhaul/lib/activity/probes').protectedBoolean(M, 'isTaxiJobActive')
  local function delegate(name)
    return function(...) return M[name](...) end
  end

  return {
    id = "taxi",
    label = "Taxi driver",
    role = "foreground",
    modes = {"career"},
    extension = "overhaul_jobs_taxi_taxi",
    lifecycle = "taxi",
    blocks = {"travelJournal", "studioRentals"},
    blockingOrder = 20,
    phoneRoute = "phone-taxi",
    blockingProbe = function(kind)
      if kind == 'travelJournal' then return journalProbe() end
      -- Rentals historically propagate errors and accept truthy running values.
      return not not (M.isTaxiJobActive and M.isTaxiJobActive())
    end,
    actions = {
      setAvailable = delegate("setAvailable"),
      prepareTaxiJob = delegate("prepareTaxiJob"),
      acceptJob = delegate("acceptJob"),
      rejectJob = delegate("rejectJob"),
      stopTaxiJob = delegate("stopTaxiJob"),
      requestTaxiState = delegate("requestTaxiState"),
    },
    probe = function() return M.isTaxiJobActive and M.isTaxiJobActive() or false end,
    save = delegate("onOverhaulSaveCurrentProfile"),
    transitions = {
      save = delegate("onOverhaulSaveCurrentProfile"),
      switch = delegate("onOverhaulBeforeSetProfile"),
      stop = delegate("onOverhaulActive"),
      unload = delegate("onClientEndMission"),
    },
    resources = {"route", "parking"},
    settlement = "owner",
    economyKeys = {"taxi"},
  }
end
