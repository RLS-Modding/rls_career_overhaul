-- Quarry activity contract and host actions.
-- The quarry owner keeps contract flow, truck state and persistence.
return function(M)
  local function delegate(name)
    return function(...) return M[name](...) end
  end

  return {
    id = "quarry",
    label = "Quarry contracts",
    role = "foreground",
    modes = {"career"},
    extension = "overhaul_jobs_quarry_quarry",
    lifecycle = "quarry",
    actions = {
      requestQuarryState = delegate("requestQuarryState"),
      acceptContractFromUI = delegate("acceptContractFromUI"),
      declineAllContracts = delegate("declineAllContracts"),
      abandonContractFromUI = delegate("abandonContractFromUI"),
      finalizeContractFromUI = delegate("finalizeContractFromUI"),
      selectZoneFromUI = delegate("selectZoneFromUI"),
      sendTruckFromUI = delegate("sendTruckFromUI"),
      swapZoneFromUI = delegate("swapZoneFromUI"),
      setZoneWaypointFromUI = delegate("setZoneWaypointFromUI"),
    },
    save = delegate("onOverhaulSaveCurrentProfile"),
    transitions = {
      save = delegate("onOverhaulSaveCurrentProfile"),
      stop = delegate("onOverhaulActive"),
      unload = delegate("onClientEndMission"),
    },
    resources = {"vehicle", "route", "hud"},
    settlement = "owner",
  }
end
