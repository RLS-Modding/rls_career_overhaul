-- The dyno session as an activity definition: each callable field delegates to the dyno load that built it,
-- so the host always reaches the current load, and nothing here keeps state or writes.
return function(M)
  local function delegate(name)
    return function(...) return M[name](...) end
  end

  local actions = {}
  for _, name in ipairs({"requestSessionData", "startSession", "repairAndStart", "startPull", "retryPull",
      "saveCurrentPull", "deleteSavedPull", "leaveSession", "openTuning", "openMaintenance"}) do
    actions[name] = delegate(name)
  end

  return {
    id = "dyno",
    label = "Dyno session",
    role = "foreground",
    modes = {"career"},
    extension = "overhaul_career_parts_dyno_dynoSession",
    lifecycle = "dyno",
    actions = actions,
    save = delegate("onOverhaulSaveCurrentProfile"),
    transitions = {
      save = delegate("onOverhaulSaveCurrentProfile"),
      unload = delegate("onClientEndMission"),
    },
    resources = {"camera", "input", "freeze", "vehicle", "hud"},
    settlement = "owner",
    economyKeys = {},
  }
end
