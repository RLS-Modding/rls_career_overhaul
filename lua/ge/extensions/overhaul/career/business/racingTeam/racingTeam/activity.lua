-- Describes the racing team's load for the career activity list; the engine still owns every lifecycle hook.
-- Every action and hook delegates to the facade M, so this part holds no state of its own.
return function(M)

  local function delegate(name) return function(...) return M[name](...) end end

  local actions = {}
  for _, name in ipairs({
    'hireTech', 'fireTech', 'assignJobToTech', 'stopTechFromJob', 'updateTechName',
    'assignFleetVehicleToDriver', 'setRacingTeamManagerAutoAssign', 'setRacingTeamManagerAssignInterval',
    'racingTeamMilestoneSplashOpen',
  }) do actions[name] = delegate(name) end

  return {
    id = 'racingTeam', label = 'Racing team: races, fleet and finances', role = 'business',
    modes = {'career'}, extension = 'overhaul_career_business_racingTeam_racingTeam', lifecycle = 'racingTeam',
    actions = actions, save = delegate('onOverhaulSaveCurrentProfile'),
    transitions = {save = delegate('onOverhaulSaveCurrentProfile'), stop = delegate('onOverhaulActive'),
      switch = delegate('onOverhaulBeforeSetProfile')},
    resources = {'vehicle', 'timer'}, settlement = 'owner', economyKeys = {},
  }
end
