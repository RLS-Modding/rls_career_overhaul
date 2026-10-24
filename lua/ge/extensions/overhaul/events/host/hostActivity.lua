-- Activity definitions bound to one host load for race, drag, burnout and tractor pull.
-- The activity host adopts these delegates; read adapters, definitions and public exports.
return function(host)
  local function delegate(name)
    return function(...)
      return host[name](...)
    end
  end

  local function event(id, label, economyKeys)
    return {
      id = id,
      label = label,
      role = "foreground",
      modes = { "career", "freeroam" },
      extension = "overhaul_events_host",
      lifecycle = id,
      actions = { beginFreeroamRace = delegate("beginFreeroamRace") },
      transitions = {
        stop = delegate("onOverhaulActive"),
        unload = delegate("onClientEndMission"),
      },
      resources = { "route", "traffic", "timer" },
      settlement = "owner",
      economyKeys = economyKeys,
    }
  end

  return {
    freeroamRace = event("freeroamRace", "Freeroam races", { "freeroam" }),
    tractorPull = event("tractorPull", "Tractor pull", {}),
    burnout = event("burnout", "Burnout competitions", { "burnout", "burnoutComp" }),
    drag = event("drag", "Drag, RLS strips", {}),
  }
end
