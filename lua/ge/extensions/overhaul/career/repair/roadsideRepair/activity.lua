-- Published by the registry's POI opener; UI actions resolve the service global at call time.
-- getUiData loads config and therefore is an action, never a projection.
return function()
  local function delegate(name)
    return function(...)
      -- The service lives in the career batch, so outside career there is nothing to call; the UI treats nil like an absent target (callModLua in installLuaBridgeFallbacks). Do not retain a service load in this definition.
      if not overhaul_career_career.isActive() then return nil end
      return overhaul_career_repair_roadsideService[name](...)
    end
  end
  return {
    id = 'roadside', label = 'Roadside service', role = 'service', modes = {'career'},
    extension = 'overhaul_career_repair_roadsideRepair', lifecycle = 'roadside',
    actions = {
      getUiData = delegate('getUiData'),
      performRepair = delegate('performRepair'),
      openMaintenance = delegate('openMaintenance'),
      openTuning = delegate('openTuning'),
      closeMenu = delegate('closeMenu'),
    },
    -- Neither service nor POI opener has an active predicate or lifecycle transition handler.
    transitions = {}, resources = {'vehicle', 'input'}, settlement = 'owner', economyKeys = {},
  }
end
