-- Tuning shop activity definition: the actions and save hook the business manager registers.
-- Read the action names, then the descriptor; every entry delegates to the live M exports.
return function(M)

  local function delegate(name) return function(...) return M[name](...) end end

  local ACTION_NAMES = {
    'hireTech', 'fireTech', 'assignJobToTech', 'stopTechFromJob', 'updateTechName',
    'setManagerPaused', 'updateBlacklist', 'updateManagerBlacklist', 'updateNotificationList',
    'getUIData', 'getTechData', 'getManagerData', 'getBlacklistData', 'getManagerBlacklistData',
    'getNotificationListData', 'getJobCompletionStatus', 'requestFinancesData',
  }
  local actions = {}
  for _, name in ipairs(ACTION_NAMES) do actions[name] = delegate(name) end

  return {
    id = 'tuningShop', label = 'Tuning shop: customer jobs and tech automation', role = 'business',
    modes = {'career'}, extension = 'overhaul_career_business_tuningShop_tuningShop', lifecycle = 'tuningShop',
    actions = actions, save = delegate('onOverhaulSaveCurrentProfile'),
    transitions = {save = delegate('onOverhaulSaveCurrentProfile')},
    resources = {'vehicle', 'timer'}, settlement = 'owner', economyKeys = {},
  }
end
