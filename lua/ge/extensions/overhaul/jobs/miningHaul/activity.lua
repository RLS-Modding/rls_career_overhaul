-- Mining haul activity contract and host actions.
-- The mining owner keeps shift progress, issued vehicles and settlement.
return function(M)
  local function delegate(name)
    return function(...) return M[name](...) end
  end

  return {
    id = "miningHaul",
    label = "Mining haul",
    role = "foreground",
    modes = {"career"},
    extension = "overhaul_jobs_miningHaul",
    lifecycle = "miningHaul",
    actions = {
      startShift = delegate("startShift"),
      loadTruck = delegate("loadTruck"),
      processOre = delegate("processOre"),
      repairTruck = delegate("repairTruck"),
      endShift = delegate("endShift"),
      closeUi = delegate("closeUi"),
    },
    save = delegate("onOverhaulSaveCurrentProfile"),
    transitions = {
      save = delegate("onOverhaulSaveCurrentProfile"),
      switch = delegate("onOverhaulBeforeSetProfile"),
    },
    resources = {"vehicle", "route", "hud"},
    settlement = "owner",
  }
end
