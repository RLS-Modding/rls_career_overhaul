-- Declares the standalone repo activity; company assignments stay with employment.
-- Payload reads record economy snapshots, so this descriptor deliberately has no projection.
return function(M)

  local function delegate(name)
    return function(...) return M[name](...) end
  end

  return {
    id = "repo",
    label = "Standalone repo",
    role = "foreground",
    modes = { "career" },
    extension = "overhaul_jobs_repo",
    lifecycle = "repo",
    blocks = { "travelJournal" },
    blockingOrder = 70,
    probe = function()
      local ok, instance = pcall(M.getRepoJobInstance)
      return not not (ok and instance and (instance.isMonitoring or instance.vehicleId or instance.jobCoroutine))
    end,
    actions = {
      generateJob = delegate("generateJob"),
      cancelJob = delegate("cancelJob"),
      completeJob = delegate("completeJob"),
      requestRepoState = delegate("requestRepoState"),
    },
    transitions = {
      stop = delegate("onOverhaulActive"),
      unload = delegate("onClientEndMission"),
    },
    resources = { "route", "parking", "vehicle" },
    settlement = "owner",
    economyKeys = { "repo" },
  }
end
