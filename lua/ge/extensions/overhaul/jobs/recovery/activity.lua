-- Off-road recovery activity actions, projections and lifecycle delegates.
-- The activity host calls the existing owner; it holds no separate job state.
return function(M)
  local function delegate(name)
    return function(...) return M[name](...) end
  end

  return {
    id = "offroadRecovery",
    label = "Off-road recovery",
    role = "foreground",
    modes = {"career"},
    extension = "overhaul_jobs_recovery",
    lifecycle = "offroadRecovery",
    actions = {
      requestState = delegate("requestState"),
      beginAcceptOffer = delegate("beginAcceptOffer"),
      selectRecoveryYard = delegate("selectRecoveryYard"),
      cancelYardSelection = delegate("cancelYardSelection"),
      previewOffer = delegate("previewOffer"),
      trackJob = delegate("trackJob"),
      abandonJob = delegate("abandonJob"),
      clearCompletion = delegate("clearCompletion"),
    },
    save = delegate("onOverhaulSaveCurrentProfile"),
    transitions = {
      save = delegate("onOverhaulSaveCurrentProfile"),
      switch = delegate("onOverhaulBeforeSetProfile"),
      stop = delegate("onOverhaulActive"),
      unload = delegate("onClientEndMission"),
    },
    resources = {"vehicle", "route", "hud"},
    settlement = "owner",
    economyKeys = {"offroadRecovery"},
  }
end
