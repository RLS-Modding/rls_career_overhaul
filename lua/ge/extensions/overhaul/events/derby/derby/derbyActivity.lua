-- The demolition derby as an activity definition: every callable delegates to the derby load that built it.
-- events/derby/derby.lua publishes it as M.activity; the activity host (lib/activity/access.lua) adopts it.

return function(M)
  -- Looked up on the export table at call time, so a reloaded derby is never reached through an old definition.
  local function delegate(name)
    return function(...)
      return M[name](...)
    end
  end

  -- No probe or state (the derby has no read-only payload builder) and no transitions (it answers none).
  -- The economy key is the event config's default type, the "demo" type the economy adjuster lists.
  return {
    id = "derby",
    label = "Demolition derby",
    role = "foreground",
    modes = { "career", "freeroam" },
    extension = "overhaul_events_derby_derby",
    lifecycle = "derby",
    actions = {
      startEvent = delegate("startEvent"),
      beginCountdown = delegate("beginCountdown"),
      cancelStaging = delegate("cancelStaging"),
      dismissCongratulations = delegate("dismissCongratulations"),
      dismissDemoIntro = delegate("dismissDemoIntro"),
      refreshStagingAvailability = delegate("refreshStagingAvailability"),
    },
    transitions = {},
    resources = { "vehicle", "hud", "traffic" },
    settlement = "owner",
    economyKeys = { "demo" },
  }
end
