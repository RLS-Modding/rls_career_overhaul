-- Cleanup activity contract and host actions.
-- The cleanup owner keeps spot state, rewards and persistence.
return function(M)
  local function delegate(name)
    return function(...) return M[name](...) end
  end

  return {
    id = "cleanupClub",
    label = "Clean Up Club",
    role = "map",
    modes = {"career"},
    extension = "overhaul_jobs_cleanupClub",
    lifecycle = "cleanupClub",
    actions = {
      requestPromptUi = delegate("requestPromptUi"),
      completeCleanup = delegate("completeCleanup"),
      closePrompt = delegate("closePrompt"),
    },
    save = delegate("onOverhaulSaveCurrentProfile"),
    transitions = {
      save = delegate("onOverhaulSaveCurrentProfile"),
      unload = delegate("onClientEndMission"),
    },
    resources = {"hud", "camera"},
    settlement = "owner",
  }
end
