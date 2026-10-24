-- Lifecycle descriptor for passive businesses: the engine owns production and teardown, and saves and unload call back into the owner.
-- Built by passive.lua from its public table M.
return function(M)
  local function delegate(name) return function(...) return M[name](...) end end
  return {
    id = "passiveBusiness", label = "Passive businesses", role = "business", modes = {"career"},
    extension = "overhaul_career_business_passive", lifecycle = "passiveBusiness", actions = {},
    save = delegate("onOverhaulSaveCurrentProfile"),
    transitions = {save = delegate("onOverhaulSaveCurrentProfile"), unload = delegate("onClientEndMission")},
    resources = {"timer"}, settlement = "owner", economyKeys = {},
  }
end
